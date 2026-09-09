#!/usr/bin/env bash
# Sourced by repository entrypoints. Public inputs are data, never shell code.
runtime_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime_input_keys() {
  case "$1" in
    controller) printf '%s\n' CONTROLLER_BASE_IMAGE_REF ;;
    os) printf '%s\n' DEBIAN_SNAPSHOT DEBIAN_CODENAME ;;
    languages)
      printf '%s\n' NODE_VERSION PHP_VERSION COMPOSER_VERSION MONGODB_PHP_EXTENSION_VERSION \
        PHPREDIS_VERSION ZSTD_PHP_EXTENSION_VERSION RUST_VERSION PYTHON_VERSION PIPX_VERSION ;;
    packages)
      printf '%s\n' COREPACK_VERSION UV_VERSION FD_VERSION YQ_VERSION SHFMT_VERSION GH_VERSION LEFTHOOK_VERSION \
        K9S_VERSION KUBECTX_VERSION KUBECTL_VERSION AWS_CLI_VERSION OCI_CLI_VERSION GCLOUD_CLI_VERSION \
        MULTICA_CLI_VERSION CODEX_VERSION PI_VERSION PI_MCP_ADAPTER_VERSION PI_WEB_ACCESS_VERSION \
        PI_OPENAI_SERVICE_TIER_VERSION PI_PONYTAIL_VERSION PI_CACHE_OPTIMIZER_VERSION \
        CODEBASE_MEMORY_MCP_VERSION CHROME_DEVTOOLS_MCP_VERSION ;;
    desktop) printf '%s\n' CUA_DRIVER_VERSION GOOGLE_CHROME_VERSION ;;
    all)
      local scope
      for scope in controller os languages packages desktop; do runtime_input_keys "$scope"; done ;;
    *) echo "Unknown build input scope: $1" >&2; return 1 ;;
  esac
}

# Bootstrap-safe: the controller base has Bash/coreutils, but not jq yet.
# Explicit scopes also accept the projected files consumed by installers.
runtime_versions_env() {
  local scope=${1:-all} line key value known required selected seen=' '
  local -a assignments=()
  known=$'\n'$(runtime_input_keys all)$'\n'
  required=$(runtime_input_keys "$scope") || return 1
  selected=$'\n'"$required"$'\n'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9_./:@+-]+)$ ]] || { echo 'Invalid literal versions.env assignment' >&2; return 1; }
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    [[ "$known" == *$'\n'"$key"$'\n'* ]] || { echo "Unsupported public build key: $key" >&2; return 1; }
    [[ "$seen" != *" $key "* ]] || { echo "Duplicate build key: $key" >&2; return 1; }
    seen+="$key "
    case "$key" in
      GOOGLE_CHROME_VERSION)
        [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] || { echo 'Invalid Google Chrome Debian package version' >&2; return 1; } ;;
      *_VERSION)
        [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || { echo "Invalid tool version: $key" >&2; return 1; } ;;
      DEBIAN_SNAPSHOT)
        [[ "$value" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo 'Invalid Debian snapshot' >&2; return 1; } ;;
      DEBIAN_CODENAME)
        [[ "$value" == bookworm ]] || { echo 'Unsupported Debian codename' >&2; return 1; } ;;
    esac
    [[ "$selected" != *$'\n'"$key"$'\n'* ]] || assignments+=("$line")
  done < "$runtime_root/versions.env"
  while IFS= read -r key; do
    [[ "$seen" == *" $key "* ]] || { echo "Missing build input: $key" >&2; return 1; }
  done <<< "$required"
  printf '%s\n' "${assignments[@]}" | LC_ALL=C sort
}

runtime_versions_json() {
  local values
  values=$(runtime_versions_env "${1:-all}") || return 1
  jq -Rn 'reduce inputs as $line ({}; ($line | split("=")) as $pair | . + {($pair[0]): $pair[1]})' <<< "$values"
}
runtime_npm_dependencies() {
  local group=$1
  local inputs
  inputs=$(runtime_versions_json packages) || return 1
  jq -ce --arg group "$group" '
    if $group == "providers" then {
      "@openai/codex": .CODEX_VERSION,
      "@earendil-works/pi-coding-agent": .PI_VERSION,
      "chrome-devtools-mcp": .CHROME_DEVTOOLS_MCP_VERSION,
      "corepack": .COREPACK_VERSION
    } elif $group == "pi-packages" then {
      "pi-mcp-adapter": .PI_MCP_ADAPTER_VERSION,
      "pi-web-access": .PI_WEB_ACCESS_VERSION,
      "pi-openai-service-tier": .PI_OPENAI_SERVICE_TIER_VERSION,
      "@dietrichgebert/ponytail": .PI_PONYTAIL_VERSION,
      "pi-cache-optimizer": .PI_CACHE_OPTIMIZER_VERSION
    } else error("Unknown npm group") end
    | if all(.[]; type == "string") then . else error("Missing npm version") end' <<< "$inputs"
}
runtime_npm_manifest() {
  local group=$1 deps
  deps=$(runtime_npm_dependencies "$group") || return 1
  jq -n --arg name "multica-runtime-$group" --argjson deps "$deps" \
    '{name:$name,private:true,version:"1.0.0",dependencies:$deps}'
}
runtime_check_inputs() {
  local production=${1:-} inputs base
  case "$production" in ''|--production) ;; *) echo "Unknown input check mode: $production" >&2; return 1 ;; esac
  inputs=$(runtime_versions_json) || return 1
  base=$(jq -r .CONTROLLER_BASE_IMAGE_REF <<< "$inputs")
  if [[ "$production" == --production && ! "$base" =~ ^[^[:space:]@]+:[0-9]+\.[0-9]+\.[0-9]+$ && ! "$base" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]]; then
    echo 'CONTROLLER_BASE_IMAGE_REF must use a release version tag (IMAGE:MAJOR.MINOR.PATCH) or SHA-256 digest; use --base-image for local builds' >&2
    return 1
  fi
  [[ -s "$runtime_root/build/apt-packages.txt" ]]
}

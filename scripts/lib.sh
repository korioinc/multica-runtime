#!/usr/bin/env bash
# Sourced by repository entrypoints. Public inputs are data, never shell code.
runtime_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime_versions_json() {
  local line key value json='{}'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9_./:@+-]*)$ ]] || { echo 'Invalid literal versions.env assignment' >&2; return 1; }
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    case "$key" in
      GO_VERSION) echo 'Go is owned by the controller base' >&2; return 1 ;;
      *_VERSION) [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || return 1 ;;
      CONTROLLER_BASE_IMAGE_REF|DEBIAN_SNAPSHOT|DEBIAN_CODENAME) ;;
      *) echo "Unsupported public build key: $key" >&2; return 1 ;;
    esac
    jq -e --arg key "$key" 'has($key) | not' <<< "$json" >/dev/null || { echo "Duplicate build key: $key" >&2; return 1; }
    json=$(jq -cn --argjson current "$json" --arg key "$key" --arg value "$value" '$current + {($key): $value}')
  done < "$runtime_root/versions.env"
  printf '%s\n' "$json"
}
runtime_versions_env() {
  runtime_versions_json | jq -r 'to_entries | sort_by(.key)[] | "\(.key)=\(.value)"'
}
runtime_npm_dependencies() {
  local group=$1
  runtime_versions_json | jq -ce --arg group "$group" '
    if $group == "providers" then {
      "@openai/codex": .CODEX_VERSION,
      "@earendil-works/pi-coding-agent": .PI_VERSION,
      "chrome-devtools-mcp": .CHROME_DEVTOOLS_MCP_VERSION,
      "corepack": .COREPACK_VERSION
    } elif $group == "pi-packages" then {
      "pi-mcp-adapter": .PI_MCP_ADAPTER_VERSION,
      "pi-thinking-level": .PI_THINKING_LEVEL_VERSION,
      "pi-web-access": .PI_WEB_ACCESS_VERSION,
      "pi-openai-service-tier": .PI_OPENAI_SERVICE_TIER_VERSION,
      "@dietrichgebert/ponytail": .PI_PONYTAIL_VERSION,
      "pi-cache-optimizer": .PI_CACHE_OPTIMIZER_VERSION
    } else error("Unknown npm group") end
    | if all(.[]; type == "string") then . else error("Missing npm version") end'
}
runtime_npm_manifest() {
  local group=$1 deps
  deps=$(runtime_npm_dependencies "$group")
  jq -n --arg name "multica-runtime-$group" --argjson deps "$deps" \
    '{name:$name,private:true,version:"1.0.0",dependencies:$deps}'
}
runtime_check_inputs() {
  local production=${1:-} inputs base group
  inputs=$(runtime_versions_json)
  base=$(jq -r .CONTROLLER_BASE_IMAGE_REF <<< "$inputs")
  if [[ "$production" == --production && ! "$base" =~ ^[^[:space:]@]+:[0-9]+\.[0-9]+\.[0-9]+$ && ! "$base" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]]; then
    echo 'CONTROLLER_BASE_IMAGE_REF must use a release version tag (IMAGE:MAJOR.MINOR.PATCH) or SHA-256 digest; use --base-image for local builds' >&2
    return 1
  fi
  for group in providers pi-packages; do
    runtime_npm_dependencies "$group" >/dev/null
  done
  jq -er .OCI_CLI_VERSION <<< "$inputs" >/dev/null
  jq -e '(.DEBIAN_SNAPSHOT | test("^[0-9]{8}T[0-9]{6}Z$")) and .DEBIAN_CODENAME == "bookworm"' <<< "$inputs" >/dev/null
  [[ -s "$runtime_root/build/apt-packages.txt" ]]
}

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
    } else error("Unknown npm group") end'
}
runtime_npm_manifests() {
  local group deps
  for group in providers pi-packages; do
    deps=$(runtime_npm_dependencies "$group")
    mkdir -p "$runtime_root/build/npm/$group"
    jq -n --arg name "multica-runtime-$group" --argjson deps "$deps" \
      '{name:$name,private:true,version:"1.0.0",dependencies:$deps}' > "$runtime_root/build/npm/$group/package.json"
  done
}
runtime_check_inputs() {
  local production=${1:-} inputs base group deps arch file expected
  inputs=$(runtime_versions_json)
  base=$(jq -r .CONTROLLER_BASE_IMAGE_REF <<< "$inputs")
  if [[ "$production" == --production && ! "$base" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]]; then
    echo 'No published ABI 2 base is pinned; set CONTROLLER_BASE_IMAGE_REF or explicitly use local --base-image' >&2
    return 1
  fi
  for group in providers pi-packages; do
    deps=$(runtime_npm_dependencies "$group")
    jq -e --argjson deps "$deps" '.dependencies == $deps' "$runtime_root/build/npm/$group/package.json" >/dev/null
    jq -e --argjson deps "$deps" '.packages[""].dependencies == $deps and (.packages | to_entries | all(.key == "" or (.value.version != null and .value.integrity != null)))' \
      "$runtime_root/build/npm/$group/package-lock.json" >/dev/null
  done
  expected="oci-cli==$(jq -r .OCI_CLI_VERSION <<< "$inputs")"
  [[ "$(cat "$runtime_root/build/python/oci.in")" == "$expected" ]]
  grep -Fx "$expected \\" "$runtime_root/locks/python-oci.lock" >/dev/null || { echo 'OCI direct version differs from Python lock' >&2; return 1; }
  for arch in amd64 arm64; do
    file="$runtime_root/locks/downloads-$arch.json"
    jq -e --argjson versions "$inputs" '
      ((.versions | del(.CONTROLLER_BASE_IMAGE_REF)) == ($versions | del(.CONTROLLER_BASE_IMAGE_REF))) and
      (.artifacts | all((.url | startswith("https://")) and (.sha256 | test("^[a-f0-9]{64}$"))))' "$file" >/dev/null
    [[ -s "$runtime_root/locks/apt-$arch.lock" ]]
  done
  [[ -s "$runtime_root/locks/python-oci.lock" ]]
}

#!/bin/bash
# Build-stage library. All inputs are literal values; this never evaluates them.
set -euo pipefail
tools=/opt/multica/tools
arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64) ;; *) echo 'Unsupported image architecture' >&2; exit 1 ;; esac
seen='|'
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9_./:@+-]*)$ ]] || { echo 'Invalid literal build input' >&2; exit 1; }
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  [[ "$seen" != *"|$key|"* ]] || { echo "Duplicate build input: $key" >&2; exit 1; }
  seen+="$key|"
  export "$key=$value"
done < /build-input/versions.env
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
mkdir -p "$tools/bin" /var/cache/multica-downloads
export PATH="$tools/bin:$tools/node/bin:$tools/php/bin:$tools/rust/bin:$tools/providers/node_modules/.bin:$tools/oci/bin:$tools/google-cloud-sdk/bin:/usr/local/go/bin:$PATH"
download() {
  local name=$1 destination=$2 url checksum cached temporary
  url=$(jq -er --arg name "$name" '.artifacts[$name].url' "/build-input/locks/downloads-$arch.json")
  checksum=$(jq -er --arg name "$name" '.artifacts[$name].sha256' "/build-input/locks/downloads-$arch.json")
  [[ "$url" == https://* && "$checksum" =~ ^[a-f0-9]{64}$ ]] || return 1
  cached="/var/cache/multica-downloads/$checksum"
  if [[ ! -f "$cached" ]] || ! printf '%s  %s\n' "$checksum" "$cached" | sha256sum --check --status; then
    temporary=$(mktemp /var/cache/multica-downloads/download.XXXXXX)
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 30 --max-time 1200 "$url" --output "$temporary"
    printf '%s  %s\n' "$checksum" "$temporary" | sha256sum --check --status
    mv "$temporary" "$cached"
  fi
  cp "$cached" "$destination"
}

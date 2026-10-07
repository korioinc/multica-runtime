#!/bin/bash
# Build-stage library. All inputs are literal values; this never evaluates them.
set -euo pipefail

# --- Shared installation paths and versions ---
# Prepare tool paths, architecture, and pinned versions from versions.env.
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
tools=/opt/multica/tools
arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64) ;; *) echo 'Unsupported image architecture' >&2; exit 1 ;; esac
installation_inputs=$(runtime_versions_env "${1:?installation input scope required}")
while IFS='=' read -r key value; do
  export "$key=$value"
done <<< "$installation_inputs"

# --- Temporary workspace and executable paths ---
# Reuse the download cache and remove temporary build files on exit.
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
mkdir -p "$tools/bin" /var/cache/multica-downloads
export PATH="$tools/bin:$tools/node/bin:$tools/php/bin:$tools/rust/bin:$tools/providers/node_modules/.bin:$tools/google-cloud-sdk/bin:/usr/local/go/bin:$PATH"

# --- Versioned downloads and shared cache ---
# Reuse complete downloads by URL; publish cached files only after curl succeeds.
# shellcheck source=downloads.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/downloads.sh"
download() {
  local name=$1 destination=$2 url cache_key cached temporary status
  url=$(download_url "$name" "$arch") || return
  [[ "$url" == https://* ]] || return 1
  cache_key=$(printf '%s' "$url" | sha256sum | awk '{print $1}') || return
  cached="/var/cache/multica-downloads/$cache_key"
  if [[ ! -f "$cached" ]]; then
    temporary=$(mktemp /var/cache/multica-downloads/download.XXXXXX) || return
    if curl --fail --location --silent --show-error --retry 3 --connect-timeout 30 --max-time 1200 "$url" --output "$temporary"; then
      mv "$temporary" "$cached" || { rm -f -- "$temporary"; return 1; }
    else
      status=$?
      rm -f -- "$temporary"
      return "$status"
    fi
  fi
  cp "$cached" "$destination"
}

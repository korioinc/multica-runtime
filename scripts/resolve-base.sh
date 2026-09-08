#!/usr/bin/env bash
# Resolve matching source only from the explicitly pinned base artifact.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
[[ $# == 2 && $1 == --platform && $2 =~ ^linux/(amd64|arm64)$ ]] || { echo 'Usage: resolve-base.sh --platform linux/amd64|linux/arm64' >&2; exit 2; }
runtime_check_inputs --production
base=$(runtime_versions_json | jq -er .CONTROLLER_BASE_IMAGE_REF)
docker pull --platform "$2" "$base" >&2
metadata=$(docker image inspect "$base")
revision=$(jq -er '.[0].Config.Labels["org.opencontainers.image.revision"]' <<< "$metadata")
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
[[ $(jq -er '.[0].Config.Labels["io.multica.controller-abi"]' <<< "$metadata") == 2 ]]
[[ $(jq -er '.[0] | .Os + "/" + .Architecture' <<< "$metadata") == "$2" ]]
printf '%s\n' "$revision"
[[ -z ${GITHUB_OUTPUT:-} ]] || printf 'revision=%s\n' "$revision" >> "$GITHUB_OUTPUT"

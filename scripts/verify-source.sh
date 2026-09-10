#!/bin/bash
set -euo pipefail
source_root=${1:?matching controller source required}
scratch=${2:?private writable verification directory required}
contract=/opt/multica/controller/build.json
[[ -f "$source_root/src/go.mod" && -f "$contract" ]]
arch=$(jq -er '.platform | sub("^linux/";"")' "$contract")
[[ "$arch" =~ ^(amd64|arm64)$ ]]
mkdir -p "$scratch/go-cache" "$scratch/go-mod"
export GOCACHE="$scratch/go-cache" GOMODCACHE="$scratch/go-mod" GOTOOLCHAIN=local
export CGO_ENABLED=0 GOOS=linux GOARCH="$arch"
go -C "$source_root/src" build -trimpath -buildvcs=false -ldflags '-s -w' -o "$scratch/rebuilt-runtime" ./cmd/runtime
actual=$(sha256sum "$scratch/rebuilt-runtime" | awk '{print $1}')
[[ "$actual" == "$(jq -er .runtimeSHA256 "$contract")" ]] || { echo 'Controller source does not reproduce the inherited runtime binary' >&2; exit 1; }
echo 'Matching controller source reproduced the inherited runtime binary'

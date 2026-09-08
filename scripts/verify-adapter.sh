#!/bin/bash
# Build the controller-owned fixture separately from production admission.
set -euo pipefail
source_root=${1:?matching controller source required}
output=${2:?verification output required}
umask 077
scratch=$(mktemp -d /tmp/runtime-adapter.XXXXXX)
cleanup() {
  local status=$?
  # Go's module cache deliberately has read-only directories. These are owned
  # disposable copies, so restore directory write access before unlinking them.
  if ! find "$scratch" -type d -exec chmod u+w {} + || ! rm -rf -- "$scratch"; then
    [[ "$status" != 0 ]] || status=1
  fi
  return "$status"
}
trap cleanup EXIT
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/verify-source.sh" "$source_root" "$scratch/source"
export GOCACHE="$scratch/source/go-cache" GOMODCACHE="$scratch/source/go-mod" GOTOOLCHAIN=local CGO_ENABLED=0
go -C "$source_root/src" build -trimpath -buildvcs=false -o "$scratch/verifyofficial" ./cmd/verifyofficial
LOCALVERIFY_DISPOSABLE_CONTAINER=true "$scratch/verifyofficial" --image --verification-output "$output" --evidence "$scratch/evidence"
[[ -s "$output" ]]
jq -e '.schemaVersion == 1 and .passed == true and .suite == "official-adapter-v1"' "$output" >/dev/null

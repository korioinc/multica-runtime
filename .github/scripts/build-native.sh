#!/usr/bin/env bash
# Free BuildKit's local layers before loading the same large native image.
set -euo pipefail
repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ ${1:-} == --root ]]; then
  [[ $# -ge 2 && $2 == /* ]] || exit 2
  repository=$2
  shift 2
fi
: "${RUNNER_TEMP:?}" "${BUILDX_BUILDER:?}"
archive=$(mktemp "$RUNNER_TEMP/runtime-image.XXXXXX.tar")
trap 'rm -f -- "$archive"' EXIT
df -h /
"$repository/scripts/build-image.sh" "$@" --docker-archive "$archive"
du -h "$archive"
docker buildx prune --builder "$BUILDX_BUILDER" --all --force
df -h /
docker load --input "$archive"
rm -f -- "$archive"
df -h /

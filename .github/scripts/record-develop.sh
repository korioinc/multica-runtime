#!/usr/bin/env bash
# Execute the uploaded OCI digest, then record it for develop tag publication.
set -euo pipefail
repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fail() { printf 'develop candidate blocked: %s\n' "$*" >&2; exit 1; }
[[ ${GITHUB_REF:-} == refs/heads/develop && ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail 'an exact develop revision is required'
[[ ${PLATFORM:-} == linux/amd64 || ${PLATFORM:-} == linux/arm64 ]] || fail 'a native platform is required'
[[ ${IMAGE:-} == "ghcr.io/${GITHUB_REPOSITORY,,}" ]] || fail 'the image must belong to this repository'
[[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || fail 'workflow run identity is required'
: "${RUNNER_TEMP:?}" "${METADATA_FILE:?}"
[[ $(git -C "$repository" rev-parse HEAD) == "$GITHUB_SHA" ]] || fail 'source checkout differs from the workflow revision'
digest=$(jq -er '."containerimage.digest"' "$METADATA_FILE")
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'invalid native digest'
manifest=$(docker buildx imagetools inspect "$IMAGE@$digest" --format '{{json .Manifest}}')
jq -e --arg digest "$digest" '
  .mediaType == "application/vnd.oci.image.manifest.v1+json" and
  .digest == $digest and (has("manifests") | not)
' <<<"$manifest" >/dev/null || fail 'build output must identify one native OCI manifest'
docker pull --platform "$PLATFORM" "$IMAGE@$digest"
local_image=$(docker image inspect "$IMAGE@$digest")
jq -e --arg platform "$PLATFORM" --arg revision "$GITHUB_SHA" '
  length == 1 and (.[0] | .Os + "/" + .Architecture == $platform and
    .Config.Labels["org.opencontainers.image.revision"] == $revision and
    .Config.Labels["org.opencontainers.image.version"] == "develop")
' <<<"$local_image" >/dev/null || fail 'native image differs from the requested source'
"$repository/scripts/verify-image.sh" --image "$IMAGE@$digest"
mkdir -p "$RUNNER_TEMP/develop-results"
jq -cn --arg image "$IMAGE" --arg digest "$digest" --arg platform "$PLATFORM" \
  --arg revision "$GITHUB_SHA" --arg run_id "$GITHUB_RUN_ID" \
  '{image:$image,digest:$digest,platform:$platform,revision:$revision,run_id:$run_id}' \
  >"$RUNNER_TEMP/develop-results/${PLATFORM#linux/}.json"

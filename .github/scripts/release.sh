#!/usr/bin/env bash
# Publish only matching, verified native candidates; preserve immutable bytes.
set -euo pipefail
export LC_ALL=C
repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../scripts/release-lib.sh
source "$repository/scripts/release-lib.sh"

usage() {
  cat <<'USAGE'
Usage: release.sh --root ABSOLUTE_CHECKOUT --image REPOSITORY --revision FULL_COMMIT [--version VERSION] COMMAND
  plan (select an available version at or above VERSION and the published latest version)
  prepare-native --platform linux/amd64|linux/arm64
  record-native --platform linux/amd64|linux/arm64 --records DIRECTORY --controller-source DIRECTORY
  publish --records DIRECTORY
External effects use gh and docker; PATH can provide local fixture commands.
USAGE
}
fail() { printf 'release blocked: %s\n' "$*" >&2; exit 1; }
supported_platform() { [[ $1 == linux/amd64 || $1 == linux/arm64 ]]; }
valid_digest() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'invalid registry digest'; printf '%s\n' "$1"; }

root='' image='' revision='' version='' release_command='' platform='' records='' controller_source=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --root|--image|--revision|--version)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      case $1 in --root) root=$2 ;; --image) image=$2 ;; --revision) revision=$2 ;; --version) version=$2 ;; esac
      shift 2 ;;
    plan|prepare-native|record-native|publish) release_command=$1; shift; break ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
[[ $root == /* && $image =~ ^[a-z0-9][a-z0-9./_-]+$ && $revision =~ ^[0-9a-f]{40}$ && -n $release_command ]] ||
  { usage >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { usage >&2; exit 1; }
  case "$release_command:$1" in
    prepare-native:--platform|record-native:--platform) platform=$2 ;;
    record-native:--records|publish:--records) records=$2 ;;
    record-native:--controller-source) controller_source=$2 ;;
    *) usage >&2; exit 1 ;;
  esac
  shift 2
done
case $release_command in
  prepare-native|record-native) supported_platform "$platform" || fail 'a supported --platform is required' ;;
esac
case $release_command in
  record-native|publish) [[ -n $records ]] || fail '--records is required' ;;
esac
case $release_command in
  plan|publish) [[ -n ${GH_REPO:-} ]] || fail 'GH_REPO is required' ;;
esac
[[ -n $version ]] || version=$(version_read "$root/VERSION")
version_stable "$version"
[[ $(git -C "$root" rev-parse HEAD) == "$revision" ]] || fail 'revision differs from checked-out source'
scratch=$(mktemp -d "${TMPDIR:-/tmp}/runtime-release.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
revision_label=org.opencontainers.image.revision
version_label=org.opencontainers.image.version

capture_command() { "$@" >"$scratch/stdout" 2>"$scratch/stderr"; }

command_failure() {
  local operation=$1 code=$2 stream
  printf 'release blocked: %s: %s (command exit %s)\n' "$release_command" "$operation" "$code" >&2
  for stream in stdout stderr; do
    if [[ -s $scratch/$stream ]]; then
      printf '%s:\n' "$stream" >&2
      cat "$scratch/$stream" >&2 || true
      printf '\n' >&2
    fi
  done
  # A command can commit a remote write and still fail before acknowledging it.
  printf 'Completed steps may persist; inspect remote state before retrying.\n' >&2
  exit 1
}

run_command() {
  local operation=$1
  shift
  capture_command "$@" || command_failure "$operation failed" "$?"
  cat "$scratch/stdout" || fail 'cannot read command output'
}

github() {
  local response header body status code operation="GitHub lookup $1"
  if capture_command gh api --include "repos/$GH_REPO/$1"; then code=0; else code=$?; fi
  response=$(cat "$scratch/stdout") || fail 'cannot read GitHub response'
  response=${response//$'\r'/}
  [[ $response == *$'\n\n'* ]] || command_failure "$operation returned an unreadable response" "$code"
  header=${response%%$'\n\n'*} body=${response#*$'\n\n'}
  [[ $header =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]] || command_failure "$operation returned an unreadable response" "$code"
  status=${BASH_REMATCH[1]}
  if [[ $status == 404 ]]; then printf 'null\n'; return; fi
  [[ $status == 200 && $code == 0 ]] || command_failure "$operation failed (HTTP $status)" "$code"
  jq -ce 'if type == "object" then . else error("invalid GitHub object") end' <<<"$body" ||
    command_failure "$operation returned an invalid object" "$code"
}

inspect() {
  local ref=$1 field=${2:-Manifest} optional=${3:-false} result error code
  if capture_command docker buildx imagetools inspect "$ref" --format "{{json .$field}}"; then code=0; else code=$?; fi
  if [[ $code != 0 ]]; then
    error=$(cat "$scratch/stderr") || fail 'cannot read registry error'
    # An auth, transport or server failure never means the artifact is absent.
    if [[ $optional == true ]] && jq -en --arg error "$error" --arg ref "$ref" '
      ($error | ascii_downcase) as $message |
      ($message | test("manifest unknown|manifest_unknown")) or
      ($message | split($ref + ": not found")[1:] | any(. == "" or test("^\\s")))
    ' >/dev/null; then printf 'null\n'; return; fi
    command_failure "registry lookup $ref ($field) failed" "$code"
  fi
  result=$(cat "$scratch/stdout") || fail 'cannot read registry response'
  jq -ce 'if type == "object" then . else error("invalid registry object") end' <<<"$result" ||
    command_failure "registry lookup $ref ($field) returned an invalid object" "$code"
}

image_metadata() {
  local metadata
  metadata=$(inspect "$1" Image) || return 1
  jq -e --arg platform "$2" --arg revision "$revision" --arg version "$version" '
    .os + "/" + .architecture == $platform and
    .config.Labels["org.opencontainers.image.revision"] == $revision and
    .config.Labels["org.opencontainers.image.version"] == $version and
    .config.Labels["io.multica.controller-abi"] == "2" and
    (.config.Labels["io.multica.image-build-id"] | test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"))
  ' <<<"$metadata" >/dev/null || fail 'native image platform or source/build mismatch'
}

native_digest() {
  local pin
  pin=$(jq -er --arg platform "$2" '
    if has("manifests") then
      [.manifests[] | select((.platform.os == "unknown" and .platform.architecture == "unknown" and
        .annotations["vnd.docker.reference.type"] == "attestation-manifest") | not)] |
      if length == 1 and (.[0].platform.os + "/" + .[0].platform.architecture) == $platform
      then .[0].digest else error("native candidate must contain one executable of the requested platform") end
    else .digest end
  ' <<<"$1") || fail 'invalid native candidate'
  valid_digest "$pin"
}

index_entries() {
  jq -ce '
    reduce (.manifests[] | select((.platform.os == "unknown" and .platform.architecture == "unknown" and
      .annotations["vnd.docker.reference.type"] == "attestation-manifest") | not)) as $entry
      ({}; ($entry.platform.os + "/" + $entry.platform.architecture) as $name |
        if ($name == "linux/amd64" or $name == "linux/arm64") and (has($name) | not) and
           (($entry.platform.variant // "") == "" or ($name == "linux/arm64" and $entry.platform.variant == "v8")) and
           ($entry.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
        then . + {($name):$entry.digest} else error("invalid executable index entry") end) |
    if length == 2 then . else error("both native platforms are required") end
  ' <<<"$1" || fail 'release index must contain exactly one executable per supported platform'
}

source_guard() {
  local main
  main=$(github git/ref/heads/main) || return 1
  [[ $(jq -r '.object.sha // ""' <<<"$main") == "$revision" ]] || fail 'a newer or different main revision exists'
}

github_version_revision() {
  local requested_version=${1:-$version} tag target sha nested existing_release owner='' release_revision visited=' '
  tag=$(github "git/ref/tags/$requested_version") || return 1
  if [[ $tag != null ]]; then
    target=$(jq -c '.object' <<<"$tag") || fail 'invalid release tag'
    while [[ $(jq -r '.type' <<<"$target") == tag ]]; do
      sha=$(jq -r '.sha' <<<"$target") || fail 'invalid annotated release tag'
      [[ $sha =~ ^[0-9a-f]{40}$ && $visited != *" $sha "* ]] || fail 'invalid annotated release tag'
      visited="$visited$sha "
      nested=$(github "git/tags/$sha") || return 1
      target=$(jq -c '.object' <<<"$nested") || fail 'invalid annotated release tag'
    done
    jq -e '.type == "commit" and (.sha | type == "string" and test("^[0-9a-f]{40}$"))' <<<"$target" >/dev/null ||
      fail 'invalid release tag target'
    owner=$(jq -r '.sha' <<<"$target") || return 1
  fi
  existing_release=$(github "releases/tags/$requested_version") || return 1
  if [[ $existing_release != null ]]; then
    jq -e '(.target_commitish | type == "string" and test("^[0-9a-f]{40}$")) and (.draft | not) and (.prerelease | not)' \
      <<<"$existing_release" >/dev/null || fail 'GitHub release has invalid source metadata or is incomplete'
    release_revision=$(jq -r .target_commitish <<<"$existing_release") || return 1
    [[ -z $owner || $owner == "$release_revision" ]] || fail 'GitHub version metadata identifies conflicting revisions'
    owner=$release_revision
  fi
  printf '%s\n' "$owner"
}

guard() {
  local owner
  source_guard || return 1
  owner=$(github_version_revision) || return 1
  [[ -z $owner || $owner == "$revision" ]] || fail 'release version belongs to another revision'
}

published() {
  local manifest entries native_platform pin metadata build_id seen_ids=' '
  manifest=$(inspect "$image:$version" Manifest true) || return 1
  if [[ $manifest == null ]]; then printf 'null\n'; return; fi
  # Buildx only retains index annotations for OCI. Docker schema-2 lists rely
  # on both native image labels below; any supplied root metadata must agree.
  jq -e --arg revision "$revision" --arg version "$version" '
    (if has("annotations") then .annotations else {} end) as $annotations |
    .schemaVersion == 2 and ($annotations | type == "object") and
    if .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json" then
      (($annotations | has("org.opencontainers.image.revision") | not) or $annotations["org.opencontainers.image.revision"] == $revision) and
      (($annotations | has("org.opencontainers.image.version") | not) or $annotations["org.opencontainers.image.version"] == $version)
    elif .mediaType == "application/vnd.oci.image.index.v1+json" then
      $annotations["org.opencontainers.image.revision"] == $revision and
      $annotations["org.opencontainers.image.version"] == $version
    else false end
  ' <<<"$manifest" >/dev/null || fail 'published version belongs to another build'
  entries=$(index_entries "$manifest") || return 1
  for native_platform in linux/amd64 linux/arm64; do
    pin=$(jq -r --arg platform "$native_platform" '.[$platform]' <<<"$entries") || fail 'invalid release index'
    image_metadata "$image@$pin" "$native_platform" || return 1
    metadata=$(inspect "$image@$pin" Image) || return 1
    build_id=$(jq -er '.config.Labels["io.multica.image-build-id"]' <<< "$metadata") || return 1
    [[ $seen_ids != *" $build_id "* ]] || fail 'published platform images reuse an imageBuildID'
    seen_ids="$seen_ids$build_id "
  done
  valid_digest "$(jq -r '.digest' <<<"$manifest")" >/dev/null || return 1
  printf '%s\n' "$manifest"
}

index_identity() {
  local manifest=$1 entries pin metadata identity='' candidate native_platform identity_version identity_revision
  jq -e '.schemaVersion == 2 and
    (.mediaType == "application/vnd.oci.image.index.v1+json" or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json")' \
    <<<"$manifest" >/dev/null || fail 'invalid release index format'
  valid_digest "$(jq -r .digest <<<"$manifest")" >/dev/null || return 1
  entries=$(index_entries "$manifest") || return 1
  # Both platform labels must agree, including for older indexes without annotations.
  for native_platform in linux/amd64 linux/arm64; do
    pin=$(jq -r --arg platform "$native_platform" '.[$platform]' <<<"$entries") || return 1
    metadata=$(inspect "$image@$pin" Image) || return 1
    jq -e --arg platform "$native_platform" '.os + "/" + .architecture == $platform' <<<"$metadata" >/dev/null || fail 'release index platform mismatch'
    candidate=$(jq -c '{version:.config.Labels["org.opencontainers.image.version"],revision:.config.Labels["org.opencontainers.image.revision"]}' <<<"$metadata") || return 1
    [[ -z $identity || $candidate == "$identity" ]] || fail 'release platforms do not identify one source build'
    identity=$candidate
  done
  identity_version=$(jq -r .version <<<"$identity") identity_revision=$(jq -r .revision <<<"$identity")
  version_stable "$identity_version" || return 1
  [[ $identity_revision =~ ^[0-9a-f]{40}$ ]] || fail 'release source metadata cannot be ordered safely'
  jq -e --arg version "$identity_version" --arg revision "$identity_revision" '
    (if has("annotations") then .annotations else {} end) as $annotations |
    ($annotations | type == "object") and
    (($annotations | has("org.opencontainers.image.version") | not) or $annotations["org.opencontainers.image.version"] == $version) and
    (($annotations | has("org.opencontainers.image.revision") | not) or $annotations["org.opencontainers.image.revision"] == $revision)
  ' <<<"$manifest" >/dev/null || fail 'release annotations disagree with native images'
  printf '%s\n' "$identity"
}

plan_release() {
  local latest latest_identity latest_version='' latest_revision='' latest_owner latest_manifest manifest identity owner registry_owner selected published_version=false
  source_guard || return 1
  latest=$(inspect "$image:latest" Manifest true) || return 1
  if [[ $latest != null ]]; then
    latest_identity=$(index_identity "$latest") || return 1
    latest_version=$(jq -r .version <<<"$latest_identity") latest_revision=$(jq -r .revision <<<"$latest_identity")
    # Validate the observed latest even when VERSION requests a higher release line.
    latest_owner=$(github_version_revision "$latest_version") || return 1
    [[ -z $latest_owner || $latest_owner == "$latest_revision" ]] || fail 'latest and GitHub version owners disagree'
    latest_manifest=$(inspect "$image:$latest_version" Manifest true) || return 1
    if [[ $latest_manifest != null ]]; then
      identity=$(index_identity "$latest_manifest") || return 1
      [[ $(jq -r .version <<<"$identity") == "$latest_version" && $(jq -r .revision <<<"$identity") == "$latest_revision" ]] || fail 'latest and immutable version owners disagree'
    fi
    if [[ $latest_revision == "$revision" ]]; then
      [[ $latest_manifest != null && $(jq -r .digest <<<"$latest_manifest") == "$(jq -r .digest <<<"$latest")" ]] || fail 'latest has no matching immutable version index'
    fi
    if [[ $(version_compare "$version" "$latest_version") == -1 ]]; then version=$latest_version; fi
  fi
  while true; do
    owner=$(github_version_revision) || return 1
    manifest=$(inspect "$image:$version" Manifest true) || return 1
    if [[ $manifest != null ]]; then
      identity=$(index_identity "$manifest") || return 1
      [[ $(jq -r .version <<<"$identity") == "$version" ]] || fail 'version tag disagrees with native image versions'
      registry_owner=$(jq -r .revision <<<"$identity") || return 1
      [[ -z $owner || $owner == "$registry_owner" ]] || fail 'GitHub and registry version owners disagree'
      owner=$registry_owner
    fi
    if [[ $version == "$latest_version" ]]; then
      [[ -z $owner || $owner == "$latest_revision" ]] || fail 'latest and version owners disagree'
      owner=$latest_revision
      if [[ $owner == "$revision" ]]; then
        [[ $manifest != null && $(jq -r .digest <<<"$manifest") == "$(jq -r .digest <<<"$latest")" ]] || fail 'latest has no matching immutable version index'
      fi
    fi
    if [[ -z $owner || $owner == "$revision" ]]; then
      guard || return 1
      if [[ $manifest != null ]]; then
        selected=$(published) || return 1
        [[ $selected != null && $(jq -r .digest <<<"$selected") == "$(jq -r .digest <<<"$manifest")" ]] || fail 'selected release index changed during planning'
        published_version=true
      fi
      jq -cnS --arg version "$version" --argjson published "$published_version" '{version:$version,published:$published}'
      return
    fi
    version=$(version_next_patch "$version") || return 1
  done
}

native_ref() { printf '%s:build-%s-%s-%s\n' "$image" "$version" "$revision" "${1#linux/}"; }

verify_local_bytes() {
  local local_image=$1 manifest=$2 pin=$3 media_type local_digest expected raw
  media_type=$(jq -r '.[0].Descriptor.mediaType // ""' <<< "$local_image") || return 1
  case "$media_type" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
      local_digest=$(jq -er '.[0].Descriptor.digest' <<< "$local_image") || return 1
      expected=$(jq -er .digest <<< "$manifest") || return 1 ;;
    application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json)
      local_digest=$(jq -er '.[0].Descriptor.digest' <<< "$local_image") || return 1
      expected=$pin ;;
    '')
      # Classic Docker stores a config digest in Id. Containerd image stores use
      # OCI manifest/index identity, described by the Descriptor field above.
      local_digest=$(jq -er '.[0].Id' <<< "$local_image") || return 1
      raw=$(run_command 'read native manifest' docker buildx imagetools inspect "$image@$pin" --raw) || return 1
      expected=$(jq -er '.config.digest' <<< "$raw") || return 1 ;;
    *) fail 'unsupported local image descriptor' ;;
  esac
  valid_digest "$local_digest" >/dev/null || return 1
  [[ "$local_digest" == "$expected" ]] || fail 'native candidate registry bytes differ from the verified local image'
}

prepare_native() {
  local ref manifest pin reuse=false
  ref=$(native_ref "$platform")
  manifest=$(inspect "$ref" Manifest true) || return 1
  if [[ $manifest != null ]]; then
    pin=$(native_digest "$manifest" "$platform") || return 1
    image_metadata "$image@$pin" "$platform" || return 1
    run_command 'pull reusable native image' docker pull "$image@$pin" >/dev/null || return 1
    run_command 'tag reusable native image' docker tag "$image@$pin" "$ref" >/dev/null || return 1
    reuse=true
  fi
  jq -cnS --arg image "$ref" --argjson reuse "$reuse" '{image:$image,reuse:$reuse}'
}

record_native() {
  local ref local_image existing pin manifest record
  ref=$(native_ref "$platform")
  [[ -n $controller_source ]] || fail 'matching --controller-source is required'
  local_image=$(run_command 'inspect local native image' docker image inspect "$ref") || return 1
  jq -e --arg platform "$platform" --arg revision "$revision" --arg version "$version" '
    length == 1 and (.[0] | .Os + "/" + .Architecture == $platform and
      .Config.Labels["org.opencontainers.image.revision"] == $revision and
      .Config.Labels["org.opencontainers.image.version"] == $version)
  ' <<< "$local_image" >/dev/null || fail 'local candidate does not match release metadata'
  run_command 'verify native image' bash "$root/scripts/verify-image.sh" --image "$ref" --controller-source "$controller_source" >/dev/null || return 1
  local_image=$(run_command 'inspect verified native image' docker image inspect "$ref") || return 1
  existing=$(inspect "$ref" Manifest true) || return 1
  if [[ $existing != null ]]; then
    pin=$(native_digest "$existing" "$platform") || return 1
    verify_local_bytes "$local_image" "$existing" "$pin" || return 1
  else
    run_command 'push native candidate' docker push "$ref" >/dev/null || return 1
  fi
  manifest=$(inspect "$ref") || return 1
  pin=$(native_digest "$manifest" "$platform") || return 1
  verify_local_bytes "$local_image" "$manifest" "$pin" || return 1
  image_metadata "$image@$pin" "$platform" || return 1
  record=$(jq -cnS --arg platform "$platform" --arg pin "$pin" --arg version "$version" --arg revision "$revision" \
    '{platform:$platform,digest:$pin,version:$version,revision:$revision,verification:"native-runtime-image-v1"}') || fail 'cannot encode native result'
  mkdir -p -- "$records" || fail 'cannot create result directory'
  printf '%s\n' "$record" >"$records/${platform#linux/}.json" || fail 'cannot record native result'
  printf '%s\n' "$record"
}

publish_index() {
  local manifest entries='{}' path record native_platform pin actual metadata build_id seen_ids=' '
  manifest=$(published) || return 1
  if [[ $manifest != null ]]; then printf '%s\n' "$manifest"; return; fi
  for path in "$records"/*.json; do
    [[ -e $path ]] || continue
    record=$(cat -- "$path") || fail 'cannot read native result'
    native_platform=$(jq -er '.platform' <<<"$record") || fail 'invalid native result'
    supported_platform "$native_platform" || fail 'unsupported native result platform'
    jq -e --arg version "$version" --arg revision "$revision" '
      .version == $version and .revision == $revision and .verification == "native-runtime-image-v1"
    ' <<<"$record" >/dev/null || fail 'native result does not belong to this verified build'
    jq -e --arg platform "$native_platform" 'has($platform) | not' <<<"$entries" >/dev/null || fail 'duplicate native result'
    pin=$(valid_digest "$(jq -r '.digest' <<<"$record")") || return 1
    image_metadata "$image@$pin" "$native_platform" || return 1
    metadata=$(inspect "$image@$pin" Image) || return 1
    build_id=$(jq -er '.config.Labels["io.multica.image-build-id"]' <<< "$metadata") || return 1
    [[ $seen_ids != *" $build_id "* ]] || fail 'platform images must use distinct imageBuildIDs'
    seen_ids="$seen_ids$build_id "
    entries=$(jq -c --arg platform "$native_platform" --arg pin "$pin" '. + {($platform):$pin}' <<<"$entries") || fail 'invalid native results'
  done
  [[ $(jq 'length' <<<"$entries") == 2 ]] || fail 'both successful native results are required'
  guard || return 1
  run_command 'publish version index' docker buildx imagetools create --tag "$image:$version" \
    --annotation "index:$revision_label=$revision" --annotation "index:$version_label=$version" \
    "$image@$(jq -r '.["linux/amd64"]' <<<"$entries")" "$image@$(jq -r '.["linux/arm64"]' <<<"$entries")" >/dev/null || return 1
  manifest=$(published) || return 1
  [[ $manifest != null ]] || fail 'published index is missing'
  actual=$(index_entries "$manifest") || return 1
  jq -e --argjson expected "$entries" '. == $expected' <<<"$actual" >/dev/null || fail 'published index does not match verified native results'
  printf '%s\n' "$manifest"
}

publish_release() {
  local manifest pin existing_release latest latest_identity latest_version compared latest_pin
  guard || return 1
  manifest=$(publish_index) || return 1
  pin=$(valid_digest "$(jq -r '.digest' <<<"$manifest")") || return 1
  guard || return 1
  existing_release=$(github "releases/tags/$version") || return 1
  if [[ $existing_release == null ]]; then
    mkdir -p -- "$records" || fail 'cannot create release result directory'
    # shellcheck disable=SC2016
    printf 'Runtime image: `%s@%s`\n\nNative platforms: linux/amd64, linux/arm64.\n' "$image" "$pin" >"$records/release-notes.md" || fail 'cannot write release notes'
    run_command 'create GitHub release' gh release create "$version" --repo "$GH_REPO" --target "$revision" --title "$version" \
      --notes-file "$records/release-notes.md" >/dev/null || return 1
  fi
  # Workflow concurrency serializes publishers; guard again before promotion.
  guard || return 1
  latest=$(inspect "$image:latest" Manifest true) || return 1
  latest_pin=''
  if [[ $latest != null ]]; then
    latest_identity=$(index_identity "$latest") || return 1
    latest_version=$(jq -r .version <<<"$latest_identity") || return 1
    compared=$(version_compare "$latest_version" "$version") || return 1
    [[ $compared != 1 ]] || fail 'latest is newer or cannot be ordered safely'
    latest_pin=$(jq -r '.digest' <<<"$latest") || fail 'invalid latest digest'
    [[ $compared != 0 || $latest_pin == "$pin" ]] || fail 'latest version has different immutable bytes'
  fi
  if [[ $latest_pin != "$pin" ]]; then
    guard || return 1
    run_command 'promote latest index' docker buildx imagetools create --tag "$image:latest" "$image@$pin" >/dev/null || return 1
    latest=$(inspect "$image:latest") || return 1
    [[ $(jq -r '.digest' <<<"$latest") == "$pin" ]] || fail 'latest promotion did not preserve the verified index'
  fi
  jq -cnS --arg version "$version" --arg revision "$revision" --arg image "$image@$pin" \
    '{version:$version,revision:$revision,image:$image}'
}

case $release_command in
  plan)
    result=$(plan_release)
    ;;
  prepare-native) result=$(prepare_native) ;;
  record-native) result=$(record_native) ;;
  publish) result=$(publish_release) ;;
esac
printf '%s\n' "$result"
[[ -z ${GITHUB_OUTPUT:-} ]] || version_github_output "$result"

#!/usr/bin/env bash
# Exercise real release decisions against isolated persistent registry/GitHub stubs.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/checkout/scripts"
export RELEASE_FIXTURE_ROOT="$scratch/state"
export RELEASE_FIXTURE_REVISION=1111111111111111111111111111111111111111
export RELEASE_FIXTURE_CHECKOUT_REVISION=$RELEASE_FIXTURE_REVISION
export GH_REPO=fixture/runtime
export PATH="$scratch/bin:$PATH"
cat > "$scratch/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -C && $3 == rev-parse && $4 == HEAD ]]
printf '%s\n' "$RELEASE_FIXTURE_CHECKOUT_REVISION"
STUB
cat > "$scratch/checkout/scripts/verify-image.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -f "$RELEASE_FIXTURE_ROOT/verification-fails" ]]
STUB
cat > "$scratch/bin/service" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state=$RELEASE_FIXTURE_ROOT
key() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
read_manifest() {
  local path="$state/refs/$(key "$1").json"
  if [[ -f "$state/fail-registry-lookup" ]]; then echo 'registry request failed: unauthorized' >&2; return 1; fi
  if [[ -f $path ]]; then cat "$path"; else echo "$1: not found" >&2; return 1; fi
}
if [[ $(basename "$0") == gh ]]; then
  if [[ $1 == api && $2 == --include ]]; then
    endpoint=${3#repos/fixture/runtime/}
    if [[ -f "$state/fail-github-lookup" && $endpoint != git/ref/heads/main ]]; then
      printf 'HTTP/1.1 503 Service Unavailable\r\n\r\n{}\n'
      exit 1
    fi
    case "$endpoint" in
      git/ref/heads/main) body=$(jq -n --arg revision "$(cat "$state/main")" '{object:{type:"commit",sha:$revision}}') ;;
      git/ref/tags/*) path="$state/tags/${endpoint##*/}.json"; [[ -f $path ]] && body=$(cat "$path") || body=null ;;
      git/tags/*) path="$state/tag-objects/${endpoint##*/}.json"; [[ -f $path ]] && body=$(cat "$path") || body=null ;;
      releases/tags/*) path="$state/releases/${endpoint##*/}.json"; [[ -f $path ]] && body=$(cat "$path") || body=null ;;
      releases/latest)
        body=null
        if [[ -f "$state/latest-release" ]]; then
          tag=$(cat "$state/latest-release")
          if [[ -f "$state/releases/$tag.json" ]]; then
            body=$(jq --arg tag "$tag" '. + {tag_name:$tag}' "$state/releases/$tag.json")
          fi
        fi
        ;;
      *) exit 2 ;;
    esac
    if [[ $body == null ]]; then printf 'HTTP/1.1 404 Not Found\r\n\r\n{}\n'; exit 1; fi
    printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "$body"
  elif [[ $1 == release && $2 == create ]]; then
    [[ ! -f "$state/fail-release" ]] || exit 1
    tag=$3
    shift 3
    target=main
    verify_tag=false
    latest=auto
    while (($#)); do
      case "$1" in
        --target) target=$2; shift 2 ;;
        --verify-tag) verify_tag=true; shift ;;
        --latest) latest=true; shift ;;
        --latest=*) latest=${1#*=}; shift ;;
        --repo|--title|--notes-file) shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [[ ! -f "$state/releases/$tag.json" ]]
    if [[ $verify_tag == true && ! -f "$state/tags/$tag.json" ]]; then exit 1; fi
    jq -n --arg revision "$target" '{target_commitish:$revision,draft:false,prerelease:false}' > "$state/releases/$tag.json"
    if [[ ! -f "$state/tags/$tag.json" ]]; then
      jq -n --arg revision "$target" '{object:{type:"commit",sha:$revision}}' > "$state/tags/$tag.json"
    fi
    if [[ $latest != false ]]; then printf '%s\n' "$tag" > "$state/latest-release"; fi
  elif [[ $1 == release && $2 == edit ]]; then
    tag=$3
    shift 3
    latest=false
    while (($#)); do
      case "$1" in
        --latest|--latest=true) latest=true; shift ;;
        --repo) shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [[ -f "$state/releases/$tag.json" ]]
    if [[ $latest == true ]]; then
      jq -e '.draft == false and .prerelease == false' "$state/releases/$tag.json" >/dev/null
      printf '%s\n' "$tag" > "$state/latest-release"
    fi
  else exit 2; fi
  exit
fi
if [[ $1 == pull || $1 == tag ]]; then exit; fi
if [[ $1 == image && $2 == inspect ]]; then
  arch=${3##*-}
  cat "$state/local-$arch.json"
  exit
fi
if [[ $1 == push ]]; then
  arch=${2##*-}
  cp "$state/native-$arch.json" "$state/refs/$(key "$2").json"
  exit
fi
[[ $1 == buildx && $2 == imagetools ]]
if [[ $3 == inspect ]]; then
  manifest=$(read_manifest "$4")
  if [[ ${5:-} == --raw ]]; then printf '%s\n' "$manifest"; exit; fi
  if [[ ${6:-} == '{{json .Image}}' ]]; then
    pin=$(jq -r .digest <<< "$manifest")
    cat "$state/images/${pin#sha256:}.json"
  else printf '%s\n' "$manifest"; fi
elif [[ $3 == create ]]; then
  shift 3
  target=''
  refs=()
  annotations='{}'
  while (($#)); do
    case "$1" in
      --tag) target=$2; shift 2 ;;
      --annotation)
        annotation=${2#index:}
        annotations=$(jq -n --argjson previous "$annotations" --arg key "${annotation%%=*}" --arg value "${annotation#*=}" '$previous + {($key):$value}')
        shift 2 ;;
      *) refs+=("$1"); shift ;;
    esac
  done
  [[ -n $target ]]
  if [[ $target == fixture/runtime:latest && -f "$state/fail-registry-latest" ]]; then exit 1; fi
  if ((${#refs[@]} == 1)); then
    read_manifest "${refs[0]}" > "$state/refs/$(key "$target").json"
  else
    [[ ! -f "$state/fail-index" ]] || exit 1
    entries='[]'
    for ref in "${refs[@]}"; do
      manifest=$(read_manifest "$ref")
      pin=$(jq -r .digest <<< "$manifest")
      metadata=$(cat "$state/images/${pin#sha256:}.json")
      entries=$(jq -n --argjson entries "$entries" --argjson metadata "$metadata" --arg digest "$pin" '$entries + [{digest:$digest,platform:{os:$metadata.os,architecture:$metadata.architecture}}]')
    done
    # Buildx drops --annotation for Docker lists; only OCI indexes retain them.
    manifest=$(jq -n --argjson entries "$entries" --argjson annotations "$annotations" --arg digest "$(cat "$state/index-digest")" --arg format "${RELEASE_FIXTURE_INDEX_FORMAT:-oci}" '
      (if $format == "docker" then "application/vnd.docker.distribution.manifest.list.v2+json" else "application/vnd.oci.image.index.v1+json" end) as $media |
      {schemaVersion:2,mediaType:$media,digest:$digest,manifests:$entries} |
      if $format == "docker" then . else .annotations=$annotations end')
    printf '%s\n' "$manifest" > "$state/refs/$(key "$target").json"
    printf '%s\n' "$manifest" > "$state/refs/$(key "fixture/runtime@$(cat "$state/index-digest")").json"
  fi
else exit 2; fi
STUB
chmod +x "$scratch/bin/"* "$scratch/checkout/scripts/verify-image.sh"
ln -s service "$scratch/bin/docker"
ln -s service "$scratch/bin/gh"
key() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
initialize() {
  rm -rf -- "$RELEASE_FIXTURE_ROOT"
  mkdir -p "$RELEASE_FIXTURE_ROOT/refs" "$RELEASE_FIXTURE_ROOT/images" "$RELEASE_FIXTURE_ROOT/records" "$RELEASE_FIXTURE_ROOT/tags" "$RELEASE_FIXTURE_ROOT/tag-objects" "$RELEASE_FIXTURE_ROOT/releases"
  export RELEASE_FIXTURE_REVISION=1111111111111111111111111111111111111111
  export RELEASE_FIXTURE_CHECKOUT_REVISION=$RELEASE_FIXTURE_REVISION
  export RELEASE_FIXTURE_VERSION=0.1.0
  printf '%s\n' "$RELEASE_FIXTURE_REVISION" > "$RELEASE_FIXTURE_ROOT/main"
  create_tag
  native_images 0
}
create_tag() {
  jq -n --arg revision "$RELEASE_FIXTURE_REVISION" '{object:{type:"commit",sha:$revision}}' > "$RELEASE_FIXTURE_ROOT/tags/$RELEASE_FIXTURE_VERSION.json"
}
checkout_release() {
  export RELEASE_FIXTURE_VERSION=$1
  export RELEASE_FIXTURE_REVISION=$2
  export RELEASE_FIXTURE_CHECKOUT_REVISION=$RELEASE_FIXTURE_REVISION
  create_tag
}
native_images() {
  local offset=$1 arch number pin config uuid metadata manifest
  printf 'sha256:%064d\n' "$((offset + 3))" > "$RELEASE_FIXTURE_ROOT/index-digest"
  for arch in amd64 arm64; do
    if [[ $arch == amd64 ]]; then number=1; uuid=11111111-1111-4111-8111-111111111111; else number=2; uuid=22222222-2222-4222-8222-222222222222; fi
    if ((offset)); then printf -v uuid '%08d-1111-4111-8111-111111111111' "$((offset + number))"; fi
    printf -v pin 'sha256:%064d' "$((offset + number))"
    printf -v config 'sha256:%064d' "$((offset + number + 10))"
    metadata=$(jq -n --arg arch "$arch" --arg revision "$RELEASE_FIXTURE_REVISION" --arg version "$RELEASE_FIXTURE_VERSION" --arg id "$uuid" '{os:"linux",architecture:$arch,config:{Labels:{"org.opencontainers.image.revision":$revision,"org.opencontainers.image.version":$version,"io.multica.controller-abi":"2","io.multica.image-build-id":$id}}}')
    printf '%s\n' "$metadata" > "$RELEASE_FIXTURE_ROOT/images/${pin#sha256:}.json"
    jq -n --argjson metadata "$metadata" --arg id "$config" '[{Id:$id,Os:$metadata.os,Architecture:$metadata.architecture,Config:$metadata.config}]' > "$RELEASE_FIXTURE_ROOT/local-$arch.json"
    manifest=$(jq -n --arg pin "$pin" --arg config "$config" '{digest:$pin,config:{digest:$config}}')
    printf '%s\n' "$manifest" > "$RELEASE_FIXTURE_ROOT/native-$arch.json"
    printf '%s\n' "$manifest" > "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime@$pin").json"
  done
}
release() {
  local -a options=(--root "$scratch/checkout" --image fixture/runtime --revision "$RELEASE_FIXTURE_REVISION" --version "$RELEASE_FIXTURE_VERSION")
  "$root/.github/scripts/release.sh" "${options[@]}" "$@" > "$scratch/result" 2> "$scratch/error"
}
record() { release record-native --platform "linux/$1" --records "$RELEASE_FIXTURE_ROOT/records"; }
publish() { release publish --records "$RELEASE_FIXTURE_ROOT/records"; }
require_success() { if ! "$@"; then cat "$scratch/error" >&2; echo "Release fixture operation failed: $*" >&2; exit 1; fi; }
expect_blocked() { if "$@"; then echo "Release fixture unexpectedly allowed an unsafe transition at line ${BASH_LINENO[0]}: $*" >&2; exit 1; fi; }
artifact_digest() {
  local file
  file="$RELEASE_FIXTURE_ROOT/refs/$(key "$1").json"
  if [[ -f "$file" ]]; then shasum -a 256 "$file" | cut -d ' ' -f 1; else echo absent; fi
}
registry_state() {
  local file
  for file in "$RELEASE_FIXTURE_ROOT/refs/"*.json "$RELEASE_FIXTURE_ROOT/tags/"*.json "$RELEASE_FIXTURE_ROOT/releases/"*.json; do
    [[ -f $file ]] || continue
    printf '%s\n' "${file#"$RELEASE_FIXTURE_ROOT/"}"
    cat "$file"
  done
  if [[ -f "$RELEASE_FIXTURE_ROOT/latest-release" ]]; then cat "$RELEASE_FIXTURE_ROOT/latest-release"; fi
}
remember_immutable_bytes() {
  local destination=$1
  mkdir -p "$destination"
  cp -R "$RELEASE_FIXTURE_ROOT/refs" "$RELEASE_FIXTURE_ROOT/images" "$RELEASE_FIXTURE_ROOT/tags" "$RELEASE_FIXTURE_ROOT/releases" "$destination/"
  rm -f "$destination/refs/$(key fixture/runtime:latest).json"
}
require_immutable_bytes() {
  local remembered=$1 file
  for file in "$remembered/refs/"*.json "$remembered/images/"*.json "$remembered/tags/"*.json "$remembered/releases/"*.json; do
    [[ -f $file ]] || continue
    cmp "$file" "$RELEASE_FIXTURE_ROOT/${file#"$remembered/"}"
  done
}
expect_blocked_without_writes() {
  registry_state > "$scratch/before-state"
  expect_blocked "$@"
  registry_state > "$scratch/after-state"
  cmp "$scratch/before-state" "$scratch/after-state"
}
select_planned_version() {
  registry_state > "$scratch/before-plan"
  require_success release plan
  registry_state > "$scratch/after-plan"
  cmp "$scratch/before-plan" "$scratch/after-plan"
  RELEASE_FIXTURE_VERSION=$(jq -er .version "$scratch/result")
}

initialize
record amd64
before=$(artifact_digest fixture/runtime:0.1.0)
expect_blocked publish
[[ $(artifact_digest fixture/runtime:0.1.0) == "$before" ]]
touch "$RELEASE_FIXTURE_ROOT/verification-fails"
candidate_before=$(artifact_digest "fixture/runtime:build-0.1.0-$RELEASE_FIXTURE_REVISION-arm64")
expect_blocked record arm64
[[ $(artifact_digest "fixture/runtime:build-0.1.0-$RELEASE_FIXTURE_REVISION-arm64") == "$candidate_before" ]]
[[ $(artifact_digest fixture/runtime:latest) == absent ]]
rm "$RELEASE_FIXTURE_ROOT/verification-fails"
record arm64
touch "$RELEASE_FIXTURE_ROOT/fail-release"
expect_blocked publish
version_before=$(artifact_digest fixture/runtime:0.1.0)
[[ $version_before != absent && $(artifact_digest fixture/runtime:latest) == absent ]]
rm "$RELEASE_FIXTURE_ROOT/fail-release"
publish
[[ $(artifact_digest fixture/runtime:0.1.0) == "$version_before" ]]
latest_before=$(artifact_digest fixture/runtime:latest)
[[ $latest_before == "$version_before" ]]
publish
[[ $(artifact_digest fixture/runtime:latest) == "$latest_before" ]]
release prepare-native --platform linux/arm64
[[ $(artifact_digest fixture/runtime:0.1.0) == "$version_before" ]]
printf '%040d\n' 9 > "$RELEASE_FIXTURE_ROOT/main"
require_success publish
[[ $(artifact_digest fixture/runtime:latest) == "$latest_before" ]]

# The existing remote tag authorizes publication; absence or movement cannot
# create a release for an untagged commit, even after native builds finish.
initialize
record amd64
record arm64
rm "$RELEASE_FIXTURE_ROOT/tags/$RELEASE_FIXTURE_VERSION.json"
expect_blocked_without_writes release plan
expect_blocked_without_writes publish
jq -n '{object:{type:"commit",sha:"9999999999999999999999999999999999999999"}}' > "$RELEASE_FIXTURE_ROOT/tags/$RELEASE_FIXTURE_VERSION.json"
expect_blocked_without_writes release plan
expect_blocked_without_writes publish
create_tag
export RELEASE_FIXTURE_CHECKOUT_REVISION=9999999999999999999999999999999999999999
expect_blocked_without_writes release plan
expect_blocked_without_writes publish
export RELEASE_FIXTURE_CHECKOUT_REVISION=$RELEASE_FIXTURE_REVISION
cp "$RELEASE_FIXTURE_ROOT/records/amd64.json" "$RELEASE_FIXTURE_ROOT/records/duplicate.json"
expect_blocked publish
[[ $(artifact_digest fixture/runtime:latest) == absent ]]
rm "$RELEASE_FIXTURE_ROOT/records/duplicate.json"
touch "$RELEASE_FIXTURE_ROOT/fail-index"
expect_blocked publish
[[ $(artifact_digest fixture/runtime:latest) == absent ]]
rm "$RELEASE_FIXTURE_ROOT/fail-index"
arm64_metadata="$RELEASE_FIXTURE_ROOT/images/$(printf '%064d' 2).json"
cp "$arm64_metadata" "$scratch/arm64-original.json"
jq '.config.Labels["io.multica.image-build-id"] = "11111111-1111-4111-8111-111111111111"' "$arm64_metadata" > "$scratch/reused-id.json"
cp "$scratch/reused-id.json" "$arm64_metadata"
expect_blocked publish
[[ $(artifact_digest fixture/runtime:latest) == absent ]]
cp "$scratch/arm64-original.json" "$arm64_metadata"
publish
version_file="$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:0.1.0).json"
jq '.manifests += [.manifests[0]]' "$version_file" > "$scratch/duplicate-index.json"
cp "$scratch/duplicate-index.json" "$version_file"
latest_before=$(artifact_digest fixture/runtime:latest)
expect_blocked publish
[[ $(artifact_digest fixture/runtime:latest) == "$latest_before" ]]

# Annotated tags must release their peeled commit even when main has advanced.
initialize
annotated_tag=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq -n --arg tag "$annotated_tag" '{object:{type:"tag",sha:$tag}}' > "$RELEASE_FIXTURE_ROOT/tags/$RELEASE_FIXTURE_VERSION.json"
jq -n --arg revision "$RELEASE_FIXTURE_REVISION" '{object:{type:"commit",sha:$revision}}' > "$RELEASE_FIXTURE_ROOT/tag-objects/$annotated_tag.json"
printf '%040d\n' 9 > "$RELEASE_FIXTURE_ROOT/main"
select_planned_version
record amd64
record arm64
require_success publish
cmp "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime:$RELEASE_FIXTURE_VERSION").json" "$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"
# GitHub ignores target_commitish for existing tags; it can retain a branch name.
release_file="$RELEASE_FIXTURE_ROOT/releases/$RELEASE_FIXTURE_VERSION.json"
jq '.target_commitish="main"' "$release_file" > "$scratch/annotated-release"
cp "$scratch/annotated-release" "$release_file"
registry_state > "$scratch/annotated-published"
require_success publish
registry_state > "$scratch/annotated-retried"
cmp "$scratch/annotated-published" "$scratch/annotated-retried"

# Docker's containerd store exposes manifest/index IDs, unlike the classic
# config-ID store exercised above. Retrying must preserve either representation.
initialize
amd64_pin=$(printf 'sha256:%064d' 1)
arm64_pin=$(printf 'sha256:%064d' 2)
arm64_index=$(printf 'sha256:%064d' 4)
jq --arg pin "$amd64_pin" '.[0].Id=$pin | .[0].Descriptor={digest:$pin,mediaType:"application/vnd.oci.image.manifest.v1+json"}' "$RELEASE_FIXTURE_ROOT/local-amd64.json" > "$scratch/local.json"
cp "$scratch/local.json" "$RELEASE_FIXTURE_ROOT/local-amd64.json"
jq --arg pin "$arm64_index" '.[0].Id=$pin | .[0].Descriptor={digest:$pin,mediaType:"application/vnd.oci.image.index.v1+json"}' "$RELEASE_FIXTURE_ROOT/local-arm64.json" > "$scratch/local.json"
cp "$scratch/local.json" "$RELEASE_FIXTURE_ROOT/local-arm64.json"
jq -n --arg index "$arm64_index" --arg pin "$arm64_pin" '{digest:$index,manifests:[{digest:$pin,platform:{os:"linux",architecture:"arm64"}}]}' > "$RELEASE_FIXTURE_ROOT/native-arm64.json"
record amd64
record arm64
record amd64
record arm64
publish
latest_before=$(artifact_digest fixture/runtime:latest)
jq --arg wrong "$arm64_index" '.[0].Descriptor.digest=$wrong' "$RELEASE_FIXTURE_ROOT/local-amd64.json" > "$scratch/local.json"
cp "$scratch/local.json" "$RELEASE_FIXTURE_ROOT/local-amd64.json"
expect_blocked record amd64
[[ $(artifact_digest fixture/runtime:latest) == "$latest_before" ]]

# Preserve accepted version bytes across a failed release and retry, with both
# annotated OCI indexes and Docker lists whose metadata lives in child labels.
for format in oci docker; do
  export RELEASE_FIXTURE_INDEX_FORMAT=$format
  initialize
  record amd64
  expect_blocked_without_writes publish
  touch "$RELEASE_FIXTURE_ROOT/verification-fails"
  expect_blocked_without_writes record arm64
  rm "$RELEASE_FIXTURE_ROOT/verification-fails"
  record arm64
  touch "$RELEASE_FIXTURE_ROOT/fail-release"
  expect_blocked publish
  version_file="$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:0.1.0).json"
  cp "$version_file" "$scratch/format-version"
  [[ $(artifact_digest fixture/runtime:latest) == absent ]]
  # A completed index lets the workflow retry without rebuilding unavailable natives.
  touch "$RELEASE_FIXTURE_ROOT/verification-fails"
  select_planned_version
  if [[ $(jq -r .published "$scratch/result") == false ]]; then
    require_success record amd64
    require_success record arm64
  fi
  rm "$RELEASE_FIXTURE_ROOT/verification-fails"
  rm "$RELEASE_FIXTURE_ROOT/fail-release"
  require_success publish
  cmp "$scratch/format-version" "$version_file"
  cmp "$scratch/format-version" "$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"
  registry_state > "$scratch/format-committed"
  require_success publish
  registry_state > "$scratch/format-retried"
  cmp "$scratch/format-committed" "$scratch/format-retried"

  for change in \
    '.annotations["org.opencontainers.image.version"]="9.0.0"' \
    '.annotations["org.opencontainers.image.revision"]="2222222222222222222222222222222222222222"' \
    '.manifests += [.manifests[0]]' \
    '.manifests[1].digest=.manifests[0].digest'; do
    jq "$change" "$scratch/format-version" > "$version_file"
    expect_blocked_without_writes publish
  done
  if [[ $format == oci ]]; then
    jq 'del(.annotations)' "$scratch/format-version" > "$version_file"
    expect_blocked_without_writes publish
  fi
  cp "$scratch/format-version" "$version_file"
  arm64_metadata="$RELEASE_FIXTURE_ROOT/images/$(printf '%064d' 2).json"
  cp "$arm64_metadata" "$scratch/format-arm64"
  for change in \
    '.config.Labels["org.opencontainers.image.version"]="9.0.0"' \
    '.config.Labels["org.opencontainers.image.revision"]="2222222222222222222222222222222222222222"' \
    '.config.Labels["io.multica.controller-abi"]="1"' \
    '.config.Labels["io.multica.image-build-id"]="11111111-1111-4111-8111-111111111111"' \
    '.architecture="amd64"'; do
    jq "$change" "$scratch/format-arm64" > "$arm64_metadata"
    expect_blocked_without_writes publish
  done
  cp "$scratch/format-arm64" "$arm64_metadata"
  require_success publish
done

# Explicit version tags publish separately while all prior immutable bytes survive.
unset RELEASE_FIXTURE_INDEX_FORMAT
initialize
select_planned_version
first_version=$RELEASE_FIXTURE_VERSION
record amd64
record arm64
require_success publish
remember_immutable_bytes "$scratch/first-publication"
checkout_release 0.1.1 2222222222222222222222222222222222222222
select_planned_version
native_images 100
record amd64
# A retry with only one native candidate must finish the same intended publication.
select_planned_version
require_success release prepare-native --platform linux/amd64
record amd64
record arm64
require_success publish
require_immutable_bytes "$scratch/first-publication"
cmp "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime:$RELEASE_FIXTURE_VERSION").json" "$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"
RELEASE_FIXTURE_VERSION=$first_version
expect_blocked_without_writes release plan
expect_blocked_without_writes publish

# A foreign latest remains ownership evidence even after its named references vanish.
initialize
select_planned_version
first_version=$RELEASE_FIXTURE_VERSION
record amd64
record arm64
require_success publish
rm "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime:$first_version").json" "$RELEASE_FIXTURE_ROOT/tags/$first_version.json" "$RELEASE_FIXTURE_ROOT/releases/$first_version.json" "$RELEASE_FIXTURE_ROOT/latest-release"
remember_immutable_bytes "$scratch/latest-only-publication"
checkout_release 0.1.1 2222222222222222222222222222222222222222
select_planned_version
native_images 100
record amd64
record arm64
require_success publish
require_immutable_bytes "$scratch/latest-only-publication"
cmp "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime:$RELEASE_FIXTURE_VERSION").json" "$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"

# A prior revision's completed index stays immutable even if its release never finished.
initialize
record amd64
record arm64
touch "$RELEASE_FIXTURE_ROOT/fail-release"
expect_blocked publish
[[ $(artifact_digest "fixture/runtime:$RELEASE_FIXTURE_VERSION") != absent && $(artifact_digest fixture/runtime:latest) == absent ]]
rm "$RELEASE_FIXTURE_ROOT/fail-release"
remember_immutable_bytes "$scratch/interrupted-publication"
checkout_release 0.1.1 2222222222222222222222222222222222222222
select_planned_version
native_images 100
record amd64
record arm64
require_success publish
require_immutable_bytes "$scratch/interrupted-publication"
cmp "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime:$RELEASE_FIXTURE_VERSION").json" "$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"

# Unknown or contradictory ownership cannot authorize any persistent release change.
initialize
record amd64
record arm64
require_success publish
first_version=$RELEASE_FIXTURE_VERSION
latest_file="$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"
cp "$latest_file" "$scratch/ownership-latest"
checkout_release 0.1.1 2222222222222222222222222222222222222222
for change in \
  '.annotations["org.opencontainers.image.version"]="invalid"' \
  '.annotations["org.opencontainers.image.revision"]="2222222222222222222222222222222222222222"'; do
  jq "$change" "$scratch/ownership-latest" > "$latest_file"
  expect_blocked_without_writes release plan
done
cp "$scratch/ownership-latest" "$latest_file"
arm64_metadata="$RELEASE_FIXTURE_ROOT/images/$(printf '%064d' 2).json"
cp "$arm64_metadata" "$scratch/ownership-arm64"
jq --arg revision "$RELEASE_FIXTURE_REVISION" '.config.Labels["org.opencontainers.image.revision"]=$revision' "$scratch/ownership-arm64" > "$arm64_metadata"
expect_blocked_without_writes release plan
cp "$scratch/ownership-arm64" "$arm64_metadata"
tag_file="$RELEASE_FIXTURE_ROOT/tags/$first_version.json"
cp "$tag_file" "$scratch/ownership-tag"
jq '.object.sha="3333333333333333333333333333333333333333"' "$scratch/ownership-tag" > "$tag_file"
expect_blocked_without_writes release plan
cp "$scratch/ownership-tag" "$tag_file"
release_file="$RELEASE_FIXTURE_ROOT/releases/$first_version.json"
cp "$release_file" "$scratch/ownership-release"
rm "$tag_file"
jq '.target_commitish="invalid"' "$scratch/ownership-release" > "$release_file"
expect_blocked_without_writes release plan
cp "$scratch/ownership-release" "$release_file"
cp "$scratch/ownership-tag" "$tag_file"
# Requesting a higher version cannot hide disagreement between GitHub and registry owners.
checkout_release 9.0.0 "$RELEASE_FIXTURE_REVISION"
jq '.object.sha="3333333333333333333333333333333333333333"' "$scratch/ownership-tag" > "$tag_file"
jq '.target_commitish="3333333333333333333333333333333333333333"' "$scratch/ownership-release" > "$release_file"
expect_blocked_without_writes release plan
cp "$scratch/ownership-tag" "$tag_file"
cp "$scratch/ownership-release" "$release_file"
for failure in fail-github-lookup fail-registry-lookup; do
  touch "$RELEASE_FIXTURE_ROOT/$failure"
  expect_blocked_without_writes release plan
  rm "$RELEASE_FIXTURE_ROOT/$failure"
done
printf '%040d\n' 9 > "$RELEASE_FIXTURE_ROOT/main"
select_planned_version

# Publishing an older, explicitly tagged version preserves both latest pointers.
initialize
checkout_release 0.2.0 2222222222222222222222222222222222222222
native_images 100
record amd64
record arm64
require_success publish
remember_immutable_bytes "$scratch/newer-publication"
latest_before=$(artifact_digest fixture/runtime:latest)
cp "$RELEASE_FIXTURE_ROOT/latest-release" "$scratch/newer-latest-release"
checkout_release 0.1.1 1111111111111111111111111111111111111111
native_images 200
select_planned_version
record amd64
record arm64
require_success publish
require_immutable_bytes "$scratch/newer-publication"
[[ $(artifact_digest fixture/runtime:latest) == "$latest_before" ]]
cmp "$scratch/newer-latest-release" "$RELEASE_FIXTURE_ROOT/latest-release"
[[ $(artifact_digest "fixture/runtime:$RELEASE_FIXTURE_VERSION") != absent && -f "$RELEASE_FIXTURE_ROOT/releases/$RELEASE_FIXTURE_VERSION.json" ]]
registry_state > "$scratch/older-published"
require_success publish
registry_state > "$scratch/older-retried"
cmp "$scratch/older-published" "$scratch/older-retried"

# Latest pointers belong to separate services: a partially completed promotion
# cannot let a backport demote GitHub, and retries must repair either pointer.
initialize
record amd64
record arm64
require_success publish
registry_before=$(artifact_digest fixture/runtime:latest)
checkout_release 0.2.0 2222222222222222222222222222222222222222
native_images 100
record amd64
record arm64
touch "$RELEASE_FIXTURE_ROOT/fail-registry-latest"
expect_blocked publish
[[ $(artifact_digest fixture/runtime:latest) == "$registry_before" ]]
[[ $(cat "$RELEASE_FIXTURE_ROOT/latest-release") == "$RELEASE_FIXTURE_VERSION" ]]
cp "$RELEASE_FIXTURE_ROOT/latest-release" "$scratch/partial-latest-release"
remember_immutable_bytes "$scratch/partial-promotion"
rm "$RELEASE_FIXTURE_ROOT/fail-registry-latest"
checkout_release 0.1.1 1111111111111111111111111111111111111111
native_images 200
record amd64
record arm64
require_success publish
require_immutable_bytes "$scratch/partial-promotion"
cmp "$scratch/partial-latest-release" "$RELEASE_FIXTURE_ROOT/latest-release"
cmp "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime:$RELEASE_FIXTURE_VERSION").json" "$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"
checkout_release 0.2.0 2222222222222222222222222222222222222222
require_success publish
require_immutable_bytes "$scratch/partial-promotion"
cmp "$scratch/partial-latest-release" "$RELEASE_FIXTURE_ROOT/latest-release"
cmp "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime:$RELEASE_FIXTURE_VERSION").json" "$RELEASE_FIXTURE_ROOT/refs/$(key fixture/runtime:latest).json"
registry_state > "$scratch/repaired-promotion"
gh release edit 0.1.1 --repo fixture/runtime --latest
require_success publish
registry_state > "$scratch/repaired-github-promotion"
cmp "$scratch/repaired-promotion" "$scratch/repaired-github-promotion"
echo 'Release fixture passed: tagged-commit publications, immutable versions, partial/release retries, metadata ownership, tag guards and independent latest recovery'

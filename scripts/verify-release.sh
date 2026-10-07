#!/usr/bin/env bash
# Exercise release ownership and promotion decisions against local stateful stubs.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/checkout/scripts"
export RELEASE_FIXTURE_ROOT="$scratch/state"
export RELEASE_FIXTURE_REVISION=1111111111111111111111111111111111111111
export GH_REPO=fixture/runtime
export PATH="$scratch/bin:$PATH"
cat > "$scratch/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -C ]]
case "$3:$4" in
  rev-parse:HEAD) printf '%s\n' "$RELEASE_FIXTURE_REVISION" ;;
  show:*:VERSION)
    revision=${4%:VERSION}
    cat "$RELEASE_FIXTURE_ROOT/versions/$revision" ;;
  *) exit 2 ;;
esac
STUB
cat > "$scratch/checkout/scripts/verify-image.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exit 0
STUB
cat > "$scratch/bin/service" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state=$RELEASE_FIXTURE_ROOT
key() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
read_manifest() {
  local path="$state/refs/$(key "$1").json"
  if [[ -f $path ]]; then cat "$path"; else echo "$1: not found" >&2; return 1; fi
}
if [[ $(basename "$0") == gh ]]; then
  if [[ $1 == api && $2 == --include ]]; then
    endpoint=${3#repos/fixture/runtime/}
    case "$endpoint" in
      git/ref/heads/main) body=$(jq -n --arg revision "$(cat "$state/main")" '{object:{type:"commit",sha:$revision}}') ;;
      compare/*)
        revisions=${endpoint#compare/}
        base=${revisions%%...*} head=${revisions#*...}
        if [[ $base == "$head" ]]; then comparison=identical
        else comparison=ahead; fi
        body=$(jq -n --arg status "$comparison" '{status:$status}') ;;
      git/ref/tags/*) path="$state/tags/${endpoint##*/}.json"; [[ -f $path ]] && body=$(cat "$path") || body=null ;;
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
    entries='[]'
    for ref in "${refs[@]}"; do
      manifest=$(read_manifest "$ref")
      pin=$(jq -r .digest <<< "$manifest")
      metadata=$(cat "$state/images/${pin#sha256:}.json")
      entries=$(jq -n --argjson entries "$entries" --argjson metadata "$metadata" --arg digest "$pin" '$entries + [{digest:$digest,platform:{os:$metadata.os,architecture:$metadata.architecture}}]')
    done
    manifest=$(jq -n --argjson entries "$entries" --argjson annotations "$annotations" --arg digest "$(cat "$state/index-digest")" '
      {schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",digest:$digest,manifests:$entries,annotations:$annotations}')
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
  mkdir -p "$RELEASE_FIXTURE_ROOT/refs" "$RELEASE_FIXTURE_ROOT/images" "$RELEASE_FIXTURE_ROOT/records" "$RELEASE_FIXTURE_ROOT/tags" "$RELEASE_FIXTURE_ROOT/releases" "$RELEASE_FIXTURE_ROOT/versions"
  export RELEASE_FIXTURE_REVISION=1111111111111111111111111111111111111111
  export RELEASE_FIXTURE_VERSION=0.1.0
  printf '%s\n' "$RELEASE_FIXTURE_VERSION" > "$RELEASE_FIXTURE_ROOT/versions/$RELEASE_FIXTURE_REVISION"
  printf '%s\n' "$RELEASE_FIXTURE_REVISION" > "$RELEASE_FIXTURE_ROOT/main"
  create_tag
  native_images 0
}
create_tag() {
  jq -n --arg revision "$RELEASE_FIXTURE_REVISION" '{object:{type:"commit",sha:$revision}}' > "$RELEASE_FIXTURE_ROOT/tags/$RELEASE_FIXTURE_VERSION.json"
}
checkout_release() {
  local committed="$RELEASE_FIXTURE_ROOT/versions/$2"
  if [[ -f $committed ]]; then
    [[ $(cat "$committed") == "$1" ]] || { echo 'Fixture commit cannot change VERSION' >&2; exit 1; }
  else
    printf '%s\n' "$1" > "$committed"
  fi
  export RELEASE_FIXTURE_VERSION=$1
  export RELEASE_FIXTURE_REVISION=$2
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
    metadata=$(jq -n --arg arch "$arch" --arg revision "$RELEASE_FIXTURE_REVISION" --arg version "$RELEASE_FIXTURE_VERSION" --arg id "$uuid" '{os:"linux",architecture:$arch,config:{Labels:{"org.opencontainers.image.revision":$revision,"org.opencontainers.image.version":$version,"io.multica.image-build-id":$id}}}')
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
  jq -er .digest "$RELEASE_FIXTURE_ROOT/refs/$(key "$1").json"
}

# A release failure after index publication must retain the registry-reported
# identity when publication is retried.
initialize
require_success record amd64
require_success record arm64
touch "$RELEASE_FIXTURE_ROOT/fail-release"
expect_blocked publish
version_before=$(artifact_digest "fixture/runtime:$RELEASE_FIXTURE_VERSION")
rm "$RELEASE_FIXTURE_ROOT/fail-release"
require_success publish
[[ $(artifact_digest "fixture/runtime:$RELEASE_FIXTURE_VERSION") == "$version_before" ]]
[[ $(artifact_digest fixture/runtime:latest) == "$version_before" ]]
require_success publish
[[ $(artifact_digest "fixture/runtime:$RELEASE_FIXTURE_VERSION") == "$version_before" ]]

# Reject a retry whose local image identity differs from the recorded candidate.
candidate="fixture/runtime:build-$RELEASE_FIXTURE_VERSION-$RELEASE_FIXTURE_REVISION-amd64"
candidate_before=$(artifact_digest "$candidate")
native_images 100
expect_blocked record amd64
[[ $(artifact_digest "$candidate") == "$candidate_before" ]]

# Missing or reassigned release tags must reject the publication request.
rm "$RELEASE_FIXTURE_ROOT/tags/$RELEASE_FIXTURE_VERSION.json"
expect_blocked publish
[[ $(artifact_digest "fixture/runtime:$RELEASE_FIXTURE_VERSION") == "$version_before" ]]
create_tag
jq -n '{object:{type:"commit",sha:"9999999999999999999999999999999999999999"}}' > "$RELEASE_FIXTURE_ROOT/tags/$RELEASE_FIXTURE_VERSION.json"
expect_blocked publish
[[ $(artifact_digest fixture/runtime:latest) == "$version_before" ]]

# Latest pointers belong to separate services. A partial promotion followed by
# a backport must not demote GitHub, and retry must finish registry promotion.
initialize
require_success record amd64
require_success record arm64
require_success publish
first_version=$RELEASE_FIXTURE_VERSION
first_digest=$(artifact_digest "fixture/runtime:$first_version")
registry_before=$(artifact_digest fixture/runtime:latest)
checkout_release 0.2.0 2222222222222222222222222222222222222222
native_images 100
require_success record amd64
require_success record arm64
touch "$RELEASE_FIXTURE_ROOT/fail-registry-latest"
expect_blocked publish
newer_version=$RELEASE_FIXTURE_VERSION
newer_digest=$(artifact_digest "fixture/runtime:$newer_version")
[[ $(artifact_digest fixture/runtime:latest) == "$registry_before" ]]
[[ $(cat "$RELEASE_FIXTURE_ROOT/latest-release") == "$newer_version" ]]
rm "$RELEASE_FIXTURE_ROOT/fail-registry-latest"
checkout_release 0.1.1 3333333333333333333333333333333333333333
native_images 200
require_success record amd64
require_success record arm64
require_success publish
[[ $(cat "$RELEASE_FIXTURE_ROOT/latest-release") == "$newer_version" ]]
[[ $(artifact_digest fixture/runtime:latest) == "$(artifact_digest "fixture/runtime:$RELEASE_FIXTURE_VERSION")" ]]
[[ $(artifact_digest "fixture/runtime:$first_version") == "$first_digest" ]]
[[ $(artifact_digest "fixture/runtime:$newer_version") == "$newer_digest" ]]
checkout_release "$newer_version" 2222222222222222222222222222222222222222
require_success publish
[[ $(cat "$RELEASE_FIXTURE_ROOT/latest-release") == "$newer_version" ]]
[[ $(artifact_digest fixture/runtime:latest) == "$newer_digest" ]]
# Once both pointers advance, publishing the backport cannot move either back.
checkout_release 0.1.1 3333333333333333333333333333333333333333
require_success publish
[[ $(cat "$RELEASE_FIXTURE_ROOT/latest-release") == "$newer_version" ]]
[[ $(artifact_digest fixture/runtime:latest) == "$newer_digest" ]]
checkout_release "$newer_version" 2222222222222222222222222222222222222222
# Repair the opposite partial state without changing the accepted image identity.
gh release edit 0.1.1 --repo fixture/runtime --latest
require_success publish
[[ $(cat "$RELEASE_FIXTURE_ROOT/latest-release") == "$newer_version" ]]
[[ $(artifact_digest fixture/runtime:latest) == "$newer_digest" ]]
echo 'Release fixture passed: modeled publication/retry decisions, tag authorization and independent latest promotion'

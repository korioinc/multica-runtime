#!/usr/bin/env bash
# Exercise real release decisions against isolated persistent registry/GitHub stubs.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/checkout/scripts"
printf '0.1.0\n' > "$scratch/checkout/VERSION"
export RELEASE_FIXTURE_ROOT="$scratch/state"
export RELEASE_FIXTURE_REVISION=1111111111111111111111111111111111111111
export GH_REPO=fixture/runtime
export PATH="$scratch/bin:$PATH"
cat > "$scratch/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -C && $3 == rev-parse && $4 == HEAD ]]
printf '%s\n' "$RELEASE_FIXTURE_REVISION"
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
  if [[ -f $path ]]; then cat "$path"; else echo "$1: not found" >&2; return 1; fi
}
if [[ $(basename "$0") == gh ]]; then
  if [[ $1 == api && $2 == --include ]]; then
    endpoint=${3#repos/fixture/runtime/}
    case "$endpoint" in
      git/ref/heads/main) body=$(jq -n --arg revision "$(cat "$state/main")" '{object:{type:"commit",sha:$revision}}') ;;
      git/ref/tags/*) [[ -f "$state/tag" ]] && body=$(cat "$state/tag") || body=null ;;
      releases/tags/*) [[ -f "$state/release" ]] && body=$(cat "$state/release") || body=null ;;
      *) exit 2 ;;
    esac
    if [[ $body == null ]]; then printf 'HTTP/1.1 404 Not Found\r\n\r\n{}\n'; exit 1; fi
    printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "$body"
  elif [[ $1 == release && $2 == create ]]; then
    [[ ! -f "$state/fail-release" ]] || exit 1
    jq -n --arg revision "$RELEASE_FIXTURE_REVISION" '{target_commitish:$revision,draft:false,prerelease:false}' > "$state/release"
    jq -n --arg revision "$RELEASE_FIXTURE_REVISION" '{object:{type:"commit",sha:$revision}}' > "$state/tag"
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
  while (($#)); do
    case "$1" in --tag) target=$2; shift 2 ;; --annotation) shift 2 ;; *) refs+=("$1"); shift ;; esac
  done
  [[ -n $target ]]
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
    manifest=$(jq -n --argjson entries "$entries" --arg revision "$RELEASE_FIXTURE_REVISION" --arg digest "$(cat "$state/index-digest")" '{digest:$digest,manifests:$entries,annotations:{"org.opencontainers.image.revision":$revision,"org.opencontainers.image.version":"0.1.0"}}')
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
  mkdir -p "$RELEASE_FIXTURE_ROOT/refs" "$RELEASE_FIXTURE_ROOT/images" "$RELEASE_FIXTURE_ROOT/records"
  printf '%s\n' "$RELEASE_FIXTURE_REVISION" > "$RELEASE_FIXTURE_ROOT/main"
  printf 'sha256:%064d\n' 3 > "$RELEASE_FIXTURE_ROOT/index-digest"
  local arch number pin config uuid metadata manifest
  for arch in amd64 arm64; do
    if [[ $arch == amd64 ]]; then number=1; uuid=11111111-1111-4111-8111-111111111111; else number=2; uuid=22222222-2222-4222-8222-222222222222; fi
    printf -v pin 'sha256:%064d' "$number"
    printf -v config 'sha256:%064d' "$((number + 10))"
    metadata=$(jq -n --arg arch "$arch" --arg revision "$RELEASE_FIXTURE_REVISION" --arg id "$uuid" '{os:"linux",architecture:$arch,config:{Labels:{"org.opencontainers.image.revision":$revision,"org.opencontainers.image.version":"0.1.0","io.multica.controller-abi":"2","io.multica.image-build-id":$id}}}')
    printf '%s\n' "$metadata" > "$RELEASE_FIXTURE_ROOT/images/${pin#sha256:}.json"
    jq -n --argjson metadata "$metadata" --arg id "$config" '[{Id:$id,Os:$metadata.os,Architecture:$metadata.architecture,Config:$metadata.config}]' > "$RELEASE_FIXTURE_ROOT/local-$arch.json"
    manifest=$(jq -n --arg pin "$pin" --arg config "$config" '{digest:$pin,config:{digest:$config}}')
    printf '%s\n' "$manifest" > "$RELEASE_FIXTURE_ROOT/native-$arch.json"
    printf '%s\n' "$manifest" > "$RELEASE_FIXTURE_ROOT/refs/$(key "fixture/runtime@$pin").json"
  done
}
release() { "$root/.github/scripts/release.sh" --root "$scratch/checkout" --image fixture/runtime --revision "$RELEASE_FIXTURE_REVISION" "$@" > "$scratch/result" 2> "$scratch/error"; }
record() { release record-native --platform "linux/$1" --controller-source "$scratch/checkout" --records "$RELEASE_FIXTURE_ROOT/records"; }
publish() { release publish --records "$RELEASE_FIXTURE_ROOT/records"; }
expect_blocked() { if "$@"; then echo 'Release fixture unexpectedly allowed an unsafe transition' >&2; exit 1; fi; }
artifact_digest() {
  local file
  file="$RELEASE_FIXTURE_ROOT/refs/$(key "$1").json"
  if [[ -f "$file" ]]; then shasum -a 256 "$file" | cut -d ' ' -f 1; else echo absent; fi
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
expect_blocked publish
[[ $(artifact_digest fixture/runtime:latest) == "$latest_before" ]]

initialize
record amd64
record arm64
jq -n '{object:{type:"commit",sha:"9999999999999999999999999999999999999999"}}' > "$RELEASE_FIXTURE_ROOT/tag"
expect_blocked publish
[[ $(artifact_digest fixture/runtime:0.1.0) == absent ]]
rm "$RELEASE_FIXTURE_ROOT/tag"
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
echo 'Release fixture passed: failed/partial candidates, duplicate version/platform, retry bytes and stale-main promotion safeguards'

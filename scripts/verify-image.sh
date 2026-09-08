#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
usage() { echo 'Usage: verify-image.sh --image IMAGE_REF --controller-source PATH [--allow-emulation]'; }
image='' controller_source='' allow_emulation=false
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --allow-emulation) allow_emulation=true; shift; continue ;;
  esac
  (($# >= 2)) || { usage >&2; exit 2; }
  case "$1" in --image) image=$2 ;; --controller-source) controller_source=$2 ;; *) usage >&2; exit 2 ;; esac
  shift 2
done
[[ -n "$image" && -n "$controller_source" && "$image" != -* ]] || { usage >&2; exit 2; }
controller_source=$(cd -- "$controller_source" && pwd)
[[ -f "$controller_source/src/go.mod" ]] || { echo 'Matching controller source is required' >&2; exit 2; }
runtime_check_inputs ''
inspect=$(docker image inspect "$image")
image_id=$(jq -er '.[0].Id' <<< "$inspect")
platform=$(jq -er '.[0] | .Os + "/" + .Architecture' <<< "$inspect")
machine=$(docker info --format '{{.Architecture}}')
case "$machine" in aarch64|arm64) native_platform=linux/arm64 ;; x86_64|amd64) native_platform=linux/amd64 ;; *) echo 'Unsupported Docker host architecture' >&2; exit 2 ;; esac
mode=native
if [[ "$platform" != "$native_platform" ]]; then
  [[ "$allow_emulation" == true ]] || { echo "Native verification requires a $platform Docker host; current host is $native_platform" >&2; exit 1; }
  mode=emulated
fi
[[ $(jq -er '.[0].Config.User' <<< "$inspect") == 65532:65532 ]]
label=$(jq -er '.[0].Config.Labels["io.multica.image-build-id"]' <<< "$inspect")
options=(--rm --platform "$platform" --user 65532:65532 --read-only --cap-drop ALL --security-opt no-new-privileges
  --tmpfs '/home/multica/agents:rw,uid=65532,gid=65532,mode=0700'
  --tmpfs '/tmp:rw,exec,uid=65532,gid=65532,mode=0700'
  --tmpfs '/run/multica:rw,uid=65532,gid=65532,mode=0700'
  --tmpfs '/workspace:rw,exec,uid=65532,gid=65532,mode=0700'
  --mount "type=bind,src=$runtime_root/scripts,dst=/verify-input,readonly"
  --mount "type=bind,src=$runtime_root/versions.env,dst=/reference/versions.env,readonly"
  --mount "type=bind,src=$runtime_root/locks,dst=/reference/locks,readonly"
  --mount "type=bind,src=$runtime_root/build/npm,dst=/reference/npm,readonly"
  --mount "type=bind,src=$controller_source/src,dst=/controller-source/src,readonly"
  --entrypoint /bin/bash)
# A wrong checkout is a startup error, before the native/adapter suites run.
docker run "${options[@]}" "$image_id" -ec '/verify-input/verify-source.sh /controller-source /tmp/source-match'
# These direct probes have no network or credentials and never mutate the artifact.
docker run "${options[@]}" --network none -e "EXPECTED_BUILD_ID=$label" "$image_id" -ec '
  test "$(jq -er .imageBuildID /opt/multica/runtime/image.json)" = "$EXPECTED_BUILD_ID"
  cmp /reference/versions.env /opt/multica/runtime/inventory/versions.env
  arch=$(dpkg --print-architecture)
  cmp "/reference/locks/downloads-$arch.json" /opt/multica/runtime/inventory/downloads.json
  cmp "/reference/locks/apt-$arch.lock" /opt/multica/runtime/inventory/apt.lock
  cmp /reference/locks/python-oci.lock /opt/multica/runtime/inventory/python-oci.lock
  for group in providers pi-packages; do
    cmp "/reference/npm/$group/package-lock.json" "/opt/multica/tools/$group/package-lock.json"
  done
  /opt/multica/controller/runtime image verify
  /verify-input/verify-native.sh
'
# The controller-source build downloads only locked Go modules, and the adapter
# communicates with its own loopback fixtures. No host auth/config is mounted.
docker run "${options[@]}" "$image_id" -ec '/verify-input/verify-adapter.sh /controller-source /tmp/verification.json'
# Mutate only disposable container overlays, after proving the original image.
# A copied verification record must not admit a changed descriptor or daemon.
for component in descriptor daemon; do
  docker run --rm --platform "$platform" --network none --user 0:0 --cap-drop ALL --cap-add DAC_OVERRIDE \
    --security-opt no-new-privileges --entrypoint /bin/bash -e "COMPONENT=$component" "$image_id" -ec '
      descriptor=/opt/multica/runtime/image.json
      /opt/multica/controller/runtime image verify >/dev/null
      if [[ "$COMPONENT" == descriptor ]]; then
        jq '\''.imageBuildID = "00000000-0000-4000-8000-000000000001"'\'' "$descriptor" > /tmp/changed-descriptor.json
        cat /tmp/changed-descriptor.json > "$descriptor"
      else
        daemon=$(jq -er .daemon.path "$descriptor")
        printf "\\n" >> "$daemon"
      fi
      if /opt/multica/controller/runtime image verify; then
        echo "Changed image incorrectly admitted by stale verification" >&2
        exit 1
      fi
    '
done
echo "Runtime image verification passed: image=$image_id platform=$platform execution=$mode"

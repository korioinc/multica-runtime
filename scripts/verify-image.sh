#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
usage() { echo 'Usage: verify-image.sh --image IMAGE_REF [--allow-emulation]'; }
image='' allow_emulation=false
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --allow-emulation) allow_emulation=true; shift; continue ;;
  esac
  (($# >= 2)) || { usage >&2; exit 2; }
  case "$1" in --image) image=$2 ;; *) usage >&2; exit 2 ;; esac
  shift 2
done
[[ -n "$image" && "$image" != -* ]] || { usage >&2; exit 2; }
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
  --entrypoint /bin/bash)
# These direct probes have no network or credentials and never mutate the artifact.
docker run "${options[@]}" --network none -e "EXPECTED_BUILD_ID=$label" "$image_id" -ec '
  test "$(jq -er .imageBuildID /opt/multica/runtime/image.json)" = "$EXPECTED_BUILD_ID"
  cmp /reference/versions.env /opt/multica/runtime/inventory/versions.env
  /opt/multica/controller/runtime image verify
  private_root=$(mktemp -d /tmp/home.XXXXXX)
  /opt/multica/controller/runtime home layout --private-root="$private_root"
  HOME="$private_root/agents" /verify-input/verify-native.sh
'
# Mutate only disposable container overlays, after proving the original image.
# The controller must reject metadata that does not match installed binaries.
for component in descriptor daemon; do
  docker run --rm --platform "$platform" --network none --user 0:0 --cap-drop ALL --cap-add DAC_OVERRIDE \
    --security-opt no-new-privileges --entrypoint /bin/bash -e "COMPONENT=$component" "$image_id" -ec '
      descriptor=/opt/multica/runtime/image.json
      /opt/multica/controller/runtime image verify >/dev/null
      if [[ "$COMPONENT" == descriptor ]]; then
        jq '\''.daemon.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"'\'' "$descriptor" > /tmp/changed-descriptor.json
        cat /tmp/changed-descriptor.json > "$descriptor"
      else
        daemon=$(jq -er .daemon.path "$descriptor")
        printf "\\n" >> "$daemon"
      fi
      if /opt/multica/controller/runtime image verify; then
        echo "Changed image incorrectly admitted" >&2
        exit 1
      fi
    '
done
echo "Runtime image verification passed: image=$image_id platform=$platform execution=$mode"

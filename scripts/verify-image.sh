#!/usr/bin/env bash
set -euo pipefail
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
# Establish absence and admission before exercising descriptor rejection.
docker run --rm -i --platform "$platform" --network none --user 65532:65532 \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --entrypoint /bin/sh "$image_id" -eu <<'VERIFY'
packages=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n')
if printf '%s\n' "$packages" | awk '$1 ~ /^tini(-static)?(:[^[:space:]]+)?$/ && $2 != "not-installed" && $2 != "config-files" { found=1 } END { exit !found }' ||
   command -v tini >/dev/null 2>&1 || command -v tini-static >/dev/null 2>&1; then
  echo 'Runtime image still contains Tini; rebuild with the matching controller base.' >&2
  exit 1
fi
for candidate in /usr/bin/tini /usr/bin/tini-static /bin/tini /bin/tini-static; do
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    echo 'Runtime image still contains a Tini executable or link.' >&2
    exit 1
  fi
done
exec /opt/multica/controller/runtime image verify
VERIFY
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
echo "Runtime image Tini absence, admission and tamper rejection passed: image=$image_id platform=$platform execution=$mode"

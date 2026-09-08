#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
usage() { echo 'Usage: build-image.sh --image IMAGE --controller-source PATH [--base-image LOCAL_IMAGE] [--platform linux/amd64|linux/arm64] [--target installed|prepared|final]'; }
image='' controller_source='' base='' platform='' target=final
while (($#)); do
  case "$1" in --help|-h) usage; exit 0 ;; esac
  (($# >= 2)) || { usage >&2; exit 2; }
  case "$1" in
    --image) image=$2 ;;
    --controller-source) controller_source=$2 ;;
    --base-image) base=$2 ;;
    --platform) platform=$2 ;;
    --target) target=$2 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
[[ -n "$image" && -n "$controller_source" && "$image" != -* && "$target" =~ ^(installed|prepared|final)$ ]] || { usage >&2; exit 2; }
controller_source=$(cd -- "$controller_source" && pwd)
[[ -f "$controller_source/src/go.mod" && -f "$controller_source/Dockerfile" ]] || { echo 'Matching controller source is required' >&2; exit 2; }
if [[ -z "$base" ]]; then
  runtime_check_inputs --production
  base=$(runtime_versions_json | jq -er .CONTROLLER_BASE_IMAGE_REF)
else
  runtime_check_inputs
  echo "Explicit local controller base: $base"
fi
if [[ -z "$platform" ]]; then
  machine=$(docker info --format '{{.Architecture}}')
  case "$machine" in aarch64|arm64) platform=linux/arm64 ;; x86_64|amd64) platform=linux/amd64 ;; *) exit 2 ;; esac
fi
[[ "$platform" =~ ^linux/(amd64|arm64)$ ]] || { usage >&2; exit 2; }
build_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
version=$(cat "$runtime_root/VERSION")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
revision=$(git -C "$runtime_root" rev-parse HEAD)
docker buildx build --load --platform "$platform" --target "$target" \
  --build-context "controller-source=$controller_source" \
  --build-arg "CONTROLLER_BASE_IMAGE_REF=$base" --build-arg "IMAGE_BUILD_ID=$build_id" \
  --build-arg "VERSION=$version" --build-arg "COMMIT=$revision" \
  --tag "$image" "$runtime_root"
echo "Built $image ($platform, stage=$target, imageBuildID=$build_id)"
[[ "$target" == final ]] || echo 'Intermediate stage is not a deployable runtime image'

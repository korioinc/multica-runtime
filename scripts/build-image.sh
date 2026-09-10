#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=release-lib.sh
source "$runtime_root/scripts/release-lib.sh"
usage() { echo 'Usage: build-image.sh --image IMAGE [--version VERSION] [--base-image LOCAL_IMAGE] [--platform linux/amd64|linux/arm64] [--target installed|final] [--cache-from SPEC]... [--cache-to SPEC]...'; }
image='' base='' platform='' target=final version=''
# External cache is opt-in; preserve each repeated cache specification as one argument.
build_options=(--load)
while (($#)); do
  case "$1" in --help|-h) usage; exit 0 ;; esac
  (($# >= 2)) || { usage >&2; exit 2; }
  case "$1" in
    --image) image=$2 ;;
    --base-image) base=$2 ;;
    --platform) platform=$2 ;;
    --target) target=$2 ;;
    --version) version=$2 ;;
    --cache-from|--cache-to)
      [[ -n "$2" ]] || { usage >&2; exit 2; }
      build_options+=("$1" "$2") ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
[[ -n "$image" && "$image" != -* && "$target" =~ ^(installed|final)$ ]] || { usage >&2; exit 2; }
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
[[ -n "$version" ]] || version=$(version_read "$runtime_root/VERSION")
version_stable "$version"
revision=$(git -C "$runtime_root" rev-parse HEAD)
docker buildx build "${build_options[@]}" --platform "$platform" --target "$target" \
  --build-arg "CONTROLLER_BASE_IMAGE_REF=$base" --build-arg "IMAGE_BUILD_ID=$build_id" \
  --build-arg "VERSION=$version" --build-arg "COMMIT=$revision" \
  --tag "$image" "$runtime_root"
echo "Built $image ($platform, stage=$target, imageBuildID=$build_id)"
[[ "$target" == final ]] || echo 'Intermediate stage is not a deployable runtime image'

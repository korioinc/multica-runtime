#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=release-lib.sh
source "$runtime_root/scripts/release-lib.sh"
usage() { echo 'Usage: build-image.sh --image IMAGE [--version VERSION] [--base-image LOCAL_IMAGE] [--platform linux/amd64|linux/arm64] [--target installed|final] [--docker-archive PATH | --push-by-digest METADATA_PATH] [--cache-from SPEC]... [--cache-to SPEC]...'; }
image='' base='' platform='' target=final version='' docker_archive='' registry_metadata=''
# External cache is opt-in; preserve each repeated cache specification as one argument.
build_options=()
while (($#)); do
  case "$1" in --help|-h) usage; exit 0 ;; esac
  (($# >= 2)) || { usage >&2; exit 2; }
  case "$1" in
    --image) image=$2 ;;
    --base-image) base=$2 ;;
    --platform) platform=$2 ;;
    --target) target=$2 ;;
    --version) version=$2 ;;
    --docker-archive) docker_archive=$2 ;;
    --push-by-digest) registry_metadata=$2 ;;
    --cache-from|--cache-to)
      [[ -n "$2" ]] || { usage >&2; exit 2; }
      build_options+=("$1" "$2") ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
[[ -n "$image" && "$image" != -* && "$target" =~ ^(installed|final)$ ]] || { usage >&2; exit 2; }
[[ -z "$docker_archive" || -z "$registry_metadata" ]] || { usage >&2; exit 2; }
if [[ -n "$registry_metadata" ]]; then
  [[ "$image" =~ ^[a-z0-9][a-z0-9./_-]+$ && "$target" == final ]] || { usage >&2; exit 2; }
  # A native OCI manifest keeps index annotations available when the two
  # verified platforms are later promoted to the mutable develop tag.
  build_options+=(--output "type=image,name=$image,push-by-digest=true,name-canonical=true,push=true,oci-mediatypes=true"
    --metadata-file "$registry_metadata" --provenance=false --sbom=false)
elif [[ -n "$docker_archive" ]]; then
  build_options+=(--output "type=docker,dest=$docker_archive,compression=gzip" --tag "$image")
else
  build_options+=(--load --tag "$image")
fi
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
# Development image labels are explicit overrides; VERSION remains a stable
# semantic version and release.sh continues to enforce release tag ownership.
case "$version" in develop|ci) ;; *) version_stable "$version" ;; esac
revision=$(git -C "$runtime_root" rev-parse HEAD)
docker buildx build "${build_options[@]}" --platform "$platform" --target "$target" \
  --build-arg "CONTROLLER_BASE_IMAGE_REF=$base" --build-arg "IMAGE_BUILD_ID=$build_id" \
  --build-arg "VERSION=$version" --build-arg "COMMIT=$revision" \
  "$runtime_root"
if [[ -n "$registry_metadata" ]]; then
  echo "Pushed $image by digest; metadata=$registry_metadata ($platform, imageBuildID=$build_id)"
elif [[ -n "$docker_archive" ]]; then
  echo "Exported $image to $docker_archive ($platform, stage=$target, imageBuildID=$build_id)"
else
  echo "Built $image ($platform, stage=$target, imageBuildID=$build_id)"
fi
[[ "$target" == final ]] || echo 'Intermediate stage is not a deployable runtime image'

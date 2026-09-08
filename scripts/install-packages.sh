#!/bin/bash
set -euo pipefail
# shellcheck source=install-common.sh
source /build-input/scripts/install-common.sh
# Root installers must not put caches or first-run state into the final user's
# HOME. Keep this owner-local so changing it does not invalidate PHP/Rust builds.
# /opt ancestors also satisfy CBM's private-path checks for HOME-derived state.
build_home=$(mktemp -d /opt/multica/.package-home.XXXXXX)
trap 'rm -rf -- "$scratch" "$build_home"' EXIT HUP INT TERM
mkdir -m 0700 "$scratch/tmp"
export HOME="$build_home" TMPDIR="$scratch/tmp"
export XDG_CACHE_HOME="$build_home/.cache" XDG_CONFIG_HOME="$build_home/.config"
export XDG_DATA_HOME="$build_home/.local/share" XDG_STATE_HOME="$build_home/.local/state"
export GOPATH="$build_home/go" GOCACHE="$build_home/.cache/go-build" GOMODCACHE="$build_home/go/pkg/mod"
export npm_config_cache="$build_home/.npm" COREPACK_HOME="$build_home/.cache/node/corepack"
export PIP_CACHE_DIR="$build_home/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1

for group in providers pi-packages; do
  mkdir -p "$tools/$group"
  cp "/build-input/build/npm/$group/package.json" "/build-input/build/npm/$group/package-lock.json" "$tools/$group/"
  npm ci --prefix "$tools/$group" --ignore-scripts --no-audit --no-fund
done
corepack enable --install-directory "$tools/bin"

download multica "$scratch/multica.tar.gz"
tar -xzf "$scratch/multica.tar.gz" -C "$tools/bin" multica
chmod 0555 "$tools/bin/multica"

download gh "$scratch/gh.tar.gz"
tar -xzf "$scratch/gh.tar.gz" -C "$scratch"
install -m 0555 "$scratch/gh_${GH_VERSION}_linux_${arch}/bin/gh" "$tools/bin/gh"
for executable in k9s kubectx kubens; do
  download "$executable" "$scratch/$executable.tar.gz"
  mkdir "$scratch/$executable"
  tar -xzf "$scratch/$executable.tar.gz" -C "$scratch/$executable"
  install -m 0555 "$scratch/$executable/$executable" "$tools/bin/$executable"
done
for executable in yq shfmt lefthook kubectl; do
  download "$executable" "$tools/bin/$executable"
  chmod 0555 "$tools/bin/$executable"
done

download uv "$scratch/uv.tar.gz"
mkdir "$scratch/uv"
tar -xzf "$scratch/uv.tar.gz" --strip-components=1 -C "$scratch/uv"
install -m 0555 "$scratch/uv/uv" "$scratch/uv/uvx" "$tools/bin/"

download aws "$scratch/aws.zip"
unzip -q "$scratch/aws.zip" -d "$scratch/aws"
"$scratch/aws/aws/install" --install-dir "$tools/aws-cli" --bin-dir "$tools/bin"

python3 -m venv "$tools/oci"
"$tools/oci/bin/pip" install --require-hashes --no-deps --no-cache-dir -r /build-input/locks/python-oci.lock
"$tools/oci/bin/pip" check

download gcloud "$scratch/gcloud.tar.gz"
tar -xzf "$scratch/gcloud.tar.gz" -C "$tools"

download cbm "$scratch/cbm.tar.gz"
mkdir "$scratch/cbm"
tar -xzf "$scratch/cbm.tar.gz" -C "$scratch/cbm"
install -m 0555 "$scratch/cbm/codebase-memory-mcp" "$tools/bin/codebase-memory-mcp"
# Never capture build-user auth/cache/IPC in the seed. This is one public setting.
seed=/opt/multica/runtime/home-seed/.cache/codebase-memory-mcp
mkdir -p "$seed"
cbm_runtime_dir=$(mktemp -d /opt/multica/.build-cbm.XXXXXX)
trap 'rm -rf -- "$scratch" "$build_home" "$cbm_runtime_dir"' EXIT HUP INT TERM
CBM_CACHE_DIR="$seed" CBM_RUNTIME_DIR="$cbm_runtime_dir" codebase-memory-mcp config set auto_index true
rm -rf -- "$cbm_runtime_dir"
find /opt/multica/runtime/home-seed -type d -exec chmod 0755 {} +
find /opt/multica/runtime/home-seed -type f -exec chmod 0644 {} +

git lfs install --system
ln -sf /usr/bin/python3 "$tools/bin/python"
mkdir -p /opt/multica/runtime/inventory
cp /build-input/versions.env /opt/multica/runtime/inventory/versions.env
cp "/build-input/locks/downloads-$arch.json" /opt/multica/runtime/inventory/downloads.json
cp /build-input/locks/python-oci.lock /opt/multica/runtime/inventory/python-oci.lock
# Read-only installation prefixes; runtime cache/config belongs to private HOME.
chmod -R a-w "$tools"

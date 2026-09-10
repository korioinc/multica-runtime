#!/bin/bash
set -euo pipefail
# shellcheck source=install-common.sh
source /build-input/scripts/install-common.sh tools

# --- Temporary installation environment ---
# Keep installation caches and first-run state out of the final user's HOME.
build_home=$(mktemp -d /opt/multica/.tools-home.XXXXXX)
trap 'rm -rf -- "$scratch" "$build_home"' EXIT HUP INT TERM
mkdir -m 0700 "$scratch/tmp"
export HOME="$build_home" TMPDIR="$scratch/tmp"
export XDG_CACHE_HOME="$build_home/.cache" XDG_CONFIG_HOME="$build_home/.config"
export XDG_DATA_HOME="$build_home/.local/share" XDG_STATE_HOME="$build_home/.local/state"
export PIP_CACHE_DIR="$build_home/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1

# --- GitHub CLI ---
# Install gh for managing GitHub repositories, pull requests, and issues from the terminal.
download gh "$scratch/gh.tar.gz"
tar -xzf "$scratch/gh.tar.gz" -C "$scratch"
install -m 0555 "$scratch/gh_${GH_VERSION}_linux_${arch}/bin/gh" "$tools/bin/gh"

# --- File search ---
# Bookworm's fd-find is 8.6 and exposes fdfind; use the pinned upstream fd >= 8.7.
fd_archive=$(basename -- "$(download_url fd "$arch")")
download fd "$scratch/$fd_archive"
mkdir "$scratch/fd"
tar -xzf "$scratch/$fd_archive" --strip-components=1 -C "$scratch/fd"
install -m 0555 "$scratch/fd/fd" "$tools/bin/fd"
"$tools/bin/fd" --version

# --- Kubernetes navigation tools ---
# k9s: terminal cluster UI; kubectx: context switching; kubens: namespace switching.
for executable in k9s kubectx kubens; do
  download "$executable" "$scratch/$executable.tar.gz"
  mkdir "$scratch/$executable"
  tar -xzf "$scratch/$executable.tar.gz" -C "$scratch/$executable"
  install -m 0555 "$scratch/$executable/$executable" "$tools/bin/$executable"
done

# --- Development and cluster CLIs ---
# yq: YAML processing; shfmt: shell formatting; lefthook: Git hooks; kubectl: Kubernetes management.
for executable in yq shfmt lefthook kubectl; do
  download "$executable" "$tools/bin/$executable"
  chmod 0555 "$tools/bin/$executable"
done

# --- Python: uv / uvx ---
# Install uv for Python packages and virtual environments, and uvx for running tools.
download uv "$scratch/uv.tar.gz"
mkdir "$scratch/uv"
tar -xzf "$scratch/uv.tar.gz" --strip-components=1 -C "$scratch/uv"
install -m 0555 "$scratch/uv/uv" "$scratch/uv/uvx" "$tools/bin/"

# --- AWS CLI ---
# Install the AWS service management CLI in its own directory.
download aws "$scratch/aws.zip"
unzip -q "$scratch/aws.zip" -d "$scratch/aws"
"$scratch/aws/aws/install" --install-dir "$tools/aws-cli" --bin-dir "$tools/bin"

# --- Oracle Cloud CLI ---
# Install the OCI CLI version from versions.env and its dependencies in a separate virtual environment.
/usr/bin/python3 -m venv "$tools/oci"
"$tools/oci/bin/pip" install --no-cache-dir "oci-cli==$OCI_CLI_VERSION"
"$tools/oci/bin/pip" check
# Expose only the CLI. Adding its venv to PATH also shadows system python3/pip.
ln -s ../oci/bin/oci "$tools/bin/oci"

# --- Google Cloud CLI ---
# Install the SDK and gcloud CLI for managing Google Cloud services.
download gcloud "$scratch/gcloud.tar.gz"
tar -xzf "$scratch/gcloud.tar.gz" -C "$tools"

# --- Git LFS / Python command setup ---
# Configure the OS-installed Git LFS system-wide and link python to python3.
git lfs install --system
ln -sf /usr/bin/python3 "$tools/bin/python"

# --- Installation records ---
# Record resolved dependencies; the prepared stage records full public inputs.
inventory=/opt/multica/runtime/inventory
mkdir -p "$inventory"
"$tools/oci/bin/pip" list --format=json > "$inventory/python-oci.json"
# Lock installed files once; later root installers can still add their own tools.
find "$tools" \( -type f -o -type d \) -perm /222 -exec chmod a-w {} +

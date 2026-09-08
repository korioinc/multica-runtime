#!/bin/bash
set -euo pipefail
# shellcheck source=install-common.sh
source /build-input/scripts/install-common.sh
# shellcheck source=lib.sh
source /build-input/scripts/lib.sh

# --- Temporary installation environment ---
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

# --- npm: AI agents and Pi extensions ---
# providers: @openai/codex, @earendil-works/pi-coding-agent, chrome-devtools-mcp, corepack.
# pi-packages: pi-mcp-adapter, pi-thinking-level, pi-web-access, pi-openai-service-tier,
# @dietrichgebert/ponytail, pi-cache-optimizer. Resolve dependencies for the versions in versions.env.
pi_seed=/opt/multica/runtime/home-seed/.pi/agent/npm
for group in providers pi-packages; do
  prefix="$tools/$group"
  npm_options=()
  if [[ "$group" == pi-packages ]]; then
    # Pi resolves npm: sources in agentDir/npm. The controller copies this seed
    # into each Pod's writable HOME, including Pods with a fresh HOME volume.
    prefix=$pi_seed
    # Match Pi's managed installs: its loader supplies the host Pi APIs.
    npm_options=(--legacy-peer-deps)
  fi
  mkdir -p "$prefix"
  runtime_npm_manifest "$group" > "$prefix/package.json"
  npm install --prefix "$prefix" "${npm_options[@]}" --package-lock=false --ignore-scripts --no-audit --no-fund
done
/bin/bash /build-input/scripts/prepare-npm-seed.sh "$pi_seed"

# --- Corepack ---
# Create Corepack shims for package managers such as Yarn and pnpm.
corepack enable --install-directory "$tools/bin"

# --- Multica CLI ---
# Install the Multica executable in the shared tools directory.
download multica "$scratch/multica.tar.gz"
tar -xzf "$scratch/multica.tar.gz" -C "$tools/bin" multica
chmod 0555 "$tools/bin/multica"

# --- GitHub CLI ---
# Install gh for managing GitHub repositories, pull requests, and issues from the terminal.
download gh "$scratch/gh.tar.gz"
tar -xzf "$scratch/gh.tar.gz" -C "$scratch"
install -m 0555 "$scratch/gh_${GH_VERSION}_linux_${arch}/bin/gh" "$tools/bin/gh"

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
python3 -m venv "$tools/oci"
"$tools/oci/bin/pip" install --no-cache-dir "oci-cli==$OCI_CLI_VERSION"
"$tools/oci/bin/pip" check

# --- Google Cloud CLI ---
# Install the SDK and gcloud CLI for managing Google Cloud services.
download gcloud "$scratch/gcloud.tar.gz"
tar -xzf "$scratch/gcloud.tar.gz" -C "$tools"

# --- Codebase Memory MCP ---
# Install the codebase indexing/search server and enable auto-indexing in the user configuration seed.
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
find /opt/multica/runtime/home-seed -type f -exec chmod u=rwX,go=rX {} +

# --- Git LFS / Python command setup ---
# Configure the OS-installed Git LFS system-wide and link python to python3.
git lfs install --system
ln -sf /usr/bin/python3 "$tools/bin/python"

# --- Installation records ---
# Copy the version inputs into the image to track installed tools.
mkdir -p /opt/multica/runtime/inventory
cp /build-input/versions.env /opt/multica/runtime/inventory/versions.env
# Read-only installation prefixes; runtime cache/config belongs to private HOME.
chmod -R a-w "$tools"

#!/bin/bash
set -euo pipefail
# shellcheck source=install-common.sh
source /build-input/scripts/install-common.sh agents

# --- Temporary installation environment ---
# Keep installation caches and first-run state out of the final user's HOME.
build_home=$(mktemp -d /opt/multica/.agents-home.XXXXXX)
trap 'rm -rf -- "$scratch" "$build_home"' EXIT HUP INT TERM
mkdir -m 0700 "$scratch/tmp"
export HOME="$build_home" TMPDIR="$scratch/tmp"
export XDG_CACHE_HOME="$build_home/.cache" XDG_CONFIG_HOME="$build_home/.config"
export XDG_DATA_HOME="$build_home/.local/share" XDG_STATE_HOME="$build_home/.local/state"
export npm_config_cache="$build_home/.npm" COREPACK_HOME="$build_home/.cache/node/corepack"

# --- npm: AI agents and Pi extensions ---
# providers: @openai/codex, @earendil-works/pi-coding-agent, chrome-devtools-mcp, corepack.
# pi-packages: pi-mcp-adapter, pi-web-access, pi-openai-service-tier,
# @dietrichgebert/ponytail, pi-cache-optimizer. Resolve dependencies for the versions in versions.env.
inventory=/opt/multica/runtime/inventory
mkdir -p "$inventory"
for group in providers pi-packages; do
  prefix="$tools/$group"
  npm_options=()
  if [[ "$group" == pi-packages ]]; then
    # HOME initialization supplies Pi's writable npm prefix before any launch.
    prefix=/opt/multica/runtime/home-seed/.pi/agent/npm
    # Match Pi's managed installs: its loader supplies the host Pi APIs.
    npm_options=(--legacy-peer-deps)
  fi
  mkdir -p "$prefix"
  runtime_npm_manifest "$group" > "$prefix/package.json"
  npm install --prefix "$prefix" "${npm_options[@]}" --package-lock=false --ignore-scripts --no-audit --no-fund
  # Package identity is stable; npm's graph traversal and relationship order are not.
  npm query --prefix "$prefix" '*' | jq -S '
    map({name,version,location,resolved,integrity} | with_entries(select(.value != null)))
    | sort_by(.location)' > "$inventory/npm-$group.json"
done

# --- Corepack ---
# Create Corepack shims for package managers such as Yarn and pnpm.
corepack enable --install-directory "$tools/bin"

# --- Multica CLI ---
# Install the Multica executable in the shared tools directory.
download multica "$scratch/multica.tar.gz"
tar -xzf "$scratch/multica.tar.gz" -C "$tools/bin" multica
chmod 0555 "$tools/bin/multica"

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

# Lock new tools without copying up read-only files from earlier image layers.
find "$tools" \( -type f -o -type d \) -perm /222 -exec chmod a-w {} +

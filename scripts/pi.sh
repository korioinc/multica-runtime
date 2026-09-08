#!/bin/bash
set -euo pipefail
pi=/opt/multica/tools/providers/node_modules/.bin/pi
packages=/opt/multica/tools/pi-packages
expected_pi_sha256=@PI_CLI_SHA256@

# The descriptor hashes this launcher; its embedded pin also binds the actual
# CLI. Verify before every entry point, including version and help probes.
if ! pi_sha256=$(/usr/bin/sha256sum -- "$pi"); then
  echo 'Pi runtime executable could not be verified' >&2
  exit 1
fi
if [[ ${pi_sha256%% *} != "$expected_pi_sha256" ]]; then
  echo 'Pi runtime executable differs from its image installation' >&2
  exit 1
fi

# Image admission and CLI help must not initialize private package state.
if [[ $# == 1 ]]; then
  case $1 in --version|--help|-h) exec "$pi" "$@" ;; esac
fi

# Match Pi's getAgentDir/normalizePath on Linux, including a literal ~/ prefix,
# file URLs, relative paths and the os.homedir() fallback when HOME is unset.
# A trailing slash preserves trailing newlines through command substitution.
agent_dir=$(/opt/multica/tools/node/bin/node -e '
const { homedir } = require("node:os");
const { join } = require("node:path");
const { fileURLToPath } = require("node:url");
let path = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
if (path === "~") path = homedir();
else if (path.startsWith("~/")) path = join(homedir(), path.slice(2));
else if (path.startsWith("file://")) path = fileURLToPath(path);
process.stdout.write(path + "/");
')
agent_dir=${agent_dir%/}
npm_dir=$agent_dir/npm
check_npm_directory() {
  if [[ -L "$npm_dir" || ( -e "$npm_dir" && ! -d "$npm_dir" ) ]]; then
    echo "Pi package initialization requires a regular directory: $npm_dir" >&2
    exit 1
  fi
}
check_npm_directory
if [[ ! -d "$npm_dir" ]]; then
  previous_umask=$(umask)
  umask 077
  mkdir -p -- "$agent_dir"
  lock=$agent_dir/.npm-initialize.lock
  if [[ -L "$lock" || ( -e "$lock" && ! -f "$lock" ) ]]; then
    echo "Pi package initialization requires a regular lock file: $lock" >&2
    exit 1
  fi
  exec {lock_fd}>>"$lock"
  flock -x "$lock_fd"
  check_npm_directory
  if [[ ! -d "$npm_dir" ]]; then
    stage=$(mktemp -d "$agent_dir/.npm-initialize.XXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp -a --no-preserve=ownership -- "$packages/." "$stage/"
    find "$stage" -type d -exec chmod 0700 {} +
    find "$stage" -type f -exec chmod u+rw,go-rwx {} +
    # A sibling staging directory keeps publication on one filesystem. -T
    # prevents nesting; -n preserves a directory created by another Pi process.
    mv -T -n -- "$stage" "$npm_dir"
    check_npm_directory
    rm -rf -- "$stage"
    trap - EXIT HUP INT TERM
  fi
  # Keep the lock inode for other waiters, but never pass its descriptor to Pi.
  exec {lock_fd}>&-
  umask "$previous_umask"
fi
exec "$pi" "$@"

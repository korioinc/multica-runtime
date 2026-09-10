#!/bin/bash
# shellcheck disable=SC2016
# Dollar expressions below are literal upstream shell source.
set -euo pipefail

# Both public commands and desktop entries use this upstream launcher. Keep its
# environment setup and exec semantics, and add the flags before caller arguments
# so an explicit -- separator cannot turn it into a positional argument.
launcher=/opt/google/chrome/google-chrome
original='exec -a "$0" "$HERE/chrome" "$@"'
[[ $(grep -Fxc -- "$original" "$launcher") == 1 ]] || {
  echo 'Unexpected Google Chrome launcher; cannot configure runtime flags' >&2
  exit 1
}
sed -i 's|^exec -a "\$0" "\$HERE/chrome" "\$@"$|exec -a "$0" "$HERE/chrome" --no-sandbox --disable-dev-shm-usage "$@"|' "$launcher"

# The bundled Puppeteer resolver otherwise bypasses the launcher for stable
# Chrome. Keep MCP's default launch on the same path without changing its CLI
# options, other channels, custom executables, or existing-browser connections.
mcp=/opt/multica/tools/providers/node_modules/chrome-devtools-mcp/build/src/third_party/index.js
original="            locations.push('/opt/google/chrome/chrome');"
[[ $(grep -Fxc -- "$original" "$mcp") == 1 ]] || {
  echo 'Unexpected Chrome DevTools MCP resolver; cannot configure Chrome launcher' >&2
  exit 1
}
sed -i "s|^            locations\.push('/opt/google/chrome/chrome');$|            locations.push('/usr/bin/google-chrome-stable');|" "$mcp"

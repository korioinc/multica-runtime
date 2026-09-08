#!/bin/bash
# Render a POSIX login-shell profile from the controller's tool search paths.
set -euo pipefail
layout=${1:?image layout required}
directories=$(jq -er '.binDirs | reverse | map(@sh) | join(" ")' "$layout")
printf '# Generated from build/layout.json; do not edit.\n'
printf 'for multica_bin_dir in %s\n' "$directories"
cat <<'PROFILE'
do
  case ":${PATH-}:" in
    *:"$multica_bin_dir":*) ;;
    *) PATH="$multica_bin_dir${PATH:+:$PATH}" ;;
  esac
done
export PATH
unset multica_bin_dir
PROFILE

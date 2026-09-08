#!/bin/bash
set -euo pipefail
# HOME seeds accept only regular files and directories. Preserve npm command
# entry points with relocatable launchers: dereferencing a Node CLI into .bin
# would change the base directory of its relative imports.
seed=$(realpath -e -- "${1:?npm installation directory required}")
[[ -d "$seed" ]]
while IFS= read -r -d '' link; do
  target=$(readlink -f -- "$link")
  if [[ $(basename -- "$(dirname -- "$link")") != .bin ||
        "$target" != "$seed/"* || ! -f "$target" || ! -x "$target" ]]; then
    echo "Unsupported npm seed link: $link" >&2
    exit 1
  fi
  relative=$(realpath --relative-to="$(dirname -- "$link")" -- "$target")
  rm -- "$link"
  # Expand the launcher's location and arguments at execution time.
  # shellcheck disable=SC2016
  printf '#!/bin/bash\nexec "$(dirname -- "$0")"/%q "$@"\n' "$relative" > "$link"
  chmod 0755 "$link"
done < <(find "$seed" -type l -print0)

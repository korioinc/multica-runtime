#!/bin/bash
set -euo pipefail
root=${1:?build input root required}
build_id=${2:?unique image build UUID required}
platform=${3:?platform required}
[[ "$build_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]
[[ "$platform" =~ ^linux/(amd64|arm64)$ ]]
# A changed entrypoint cannot run against an older Tini-bearing base.
# Reject it before version probes or descriptor publication; never repair it.
packages=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n')
if awk '$1 ~ /^tini(-static)?(:[^[:space:]]+)?$/ && $2 != "not-installed" && $2 != "config-files" { found=1 } END { exit !found }' <<< "$packages" ||
   command -v tini >/dev/null 2>&1 || command -v tini-static >/dev/null 2>&1; then
  echo 'Incompatible controller base contains Tini; select a matching Tini-free base with --base-image.' >&2
  exit 1
fi
for candidate in /usr/bin/tini /usr/bin/tini-static /bin/tini /bin/tini-static; do
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    echo 'Incompatible controller base contains a Tini executable or link; select a matching Tini-free base with --base-image.' >&2
    exit 1
  fi
done
# Agent version commands can write first-run state. Keep descriptor generation
# out of the image user's HOME before invoking the installed agents.
scratch=$(mktemp -d /opt/multica/.finalize.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -m 0700 "$scratch/home" "$scratch/tmp"
export HOME="$scratch/home" TMPDIR="$scratch/tmp"
contract=/opt/multica/controller/build.json
jq -e --arg platform "$platform" '
  .platform == $platform and
  (.runtimeSHA256 | test("^[a-f0-9]{64}$")) and (.buildID | test("^[a-f0-9]{64}$"))' "$contract" >/dev/null
controller_path=$(jq -er .runtimePath "$contract")
[[ "$(sha256sum "$controller_path" | awk '{print $1}')" == "$(jq -er .runtimeSHA256 "$contract")" ]]
[[ "$(stat -c %u /opt /opt/multica /home /home/multica | sort -u)" == 0 ]]
for parent in /opt /opt/multica /home /home/multica; do
  permissions=$(stat -c %a "$parent")
  (( (8#$permissions & 0022) == 0 ))
done

get_pin() { sed -n "s/^$1=//p" "$root/versions.env"; }
metadata() {
  local path=$1 expected=$2 resolved actual checksum
  [[ "$path" == /opt/multica/tools/* ]]
  resolved=$(readlink -f "$path")
  [[ "$resolved" == /opt/multica/tools/* && -f "$resolved" && -x "$resolved" ]]
  actual=$("$path" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?' | sed -n '1p')
  [[ "$actual" == "$expected" ]] || { echo "Installed version mismatch: $path" >&2; return 1; }
  checksum=$(sha256sum "$resolved" | awk '{print $1}')
  jq -n --arg path "$path" --arg version "$actual" --arg sha "$checksum" '{path:$path,version:$version,sha256:$sha}'
}
metadata "$(jq -er .daemon "$root/build/layout.json")" "$(get_pin MULTICA_CLI_VERSION)" | \
  jq '. + {adapterContract:"multica-v0.4.43-helper-agent-v1"}' > "$scratch/daemon.json"
# The contract identifies the helper protocol, not an allowed CLI release.
printf '{}\n' > "$scratch/providers.json"
# Use the layout as the registration inventory's single source of truth.
provider_names=$(jq -er '.providers | keys[]' "$root/build/layout.json")
while IFS= read -r provider; do
  key=$(tr '[:lower:]' '[:upper:]' <<< "$provider")_VERSION
  metadata "$(jq -er --arg provider "$provider" '.providers[$provider]' "$root/build/layout.json")" "$(get_pin "$key")" > "$scratch/provider.json"
  jq --arg name "$provider" --slurpfile provider "$scratch/provider.json" '. + {($name):$provider[0]}' "$scratch/providers.json" > "$scratch/next.json"
  mv "$scratch/next.json" "$scratch/providers.json"
done <<< "$provider_names"
# HOME is used directly by containers. Reject links that escape it, special files,
# or permissions that would expose private runtime configuration to other users.
/usr/bin/python3 - <<'PY'
import os
from pathlib import Path
import stat

home = Path('/home/multica/agents')
if home.resolve(strict=True) != home or not home.is_dir():
    raise SystemExit('Image HOME must be a real directory')

def validate(path):
    info = path.lstat()
    if (info.st_uid, info.st_gid) != (65532, 65532):
        raise SystemExit(f'Image HOME entry has unexpected ownership: {path}')
    if stat.S_ISLNK(info.st_mode):
        target = os.readlink(path)
        resolved = path.resolve(strict=True)
        if os.path.isabs(target) or not resolved.is_relative_to(home):
            raise SystemExit(f'Image HOME link escapes HOME: {path}')
        if not resolved.is_dir() and not resolved.is_file():
            raise SystemExit(f'Image HOME link targets a special file: {path}')
    elif stat.S_ISDIR(info.st_mode):
        if stat.S_IMODE(info.st_mode) != 0o700:
            raise SystemExit(f'Image HOME directory has unexpected permissions: {path}')
    elif stat.S_ISREG(info.st_mode):
        if stat.S_IMODE(info.st_mode) not in (0o600, 0o700):
            raise SystemExit(f'Image HOME file has unexpected permissions: {path}')
    else:
        raise SystemExit(f'Image HOME contains a special file: {path}')

validate(home)
for directory, directories, files in os.walk(home, followlinks=False):
    for name in directories + files:
        validate(Path(directory) / name)
PY
mkdir -p /opt/multica/runtime
# Installation stages consume subsets; provenance retains the exact public input.
mkdir -p /opt/multica/runtime/inventory
cp "$root/versions.env" /opt/multica/runtime/inventory/versions.env
jq -n --arg id "$build_id" --arg platform "$platform" \
  --slurpfile controller "$contract" --slurpfile daemon "$scratch/daemon.json" \
  --slurpfile providers "$scratch/providers.json" --slurpfile layout "$root/build/layout.json" '
  {kind:"multica-runtime-image",imageBuildID:$id,platform:$platform,
   controller:$controller[0],daemon:$daemon[0],providers:$providers[0],
   binDirs:$layout[0].binDirs,env:$layout[0].env}' \
  > /opt/multica/runtime/image.json
chmod 0444 /opt/multica/runtime/image.json

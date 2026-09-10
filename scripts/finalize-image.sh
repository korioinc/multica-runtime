#!/bin/bash
set -euo pipefail
root=${1:?build input root required}
build_id=${2:?unique image build UUID required}
platform=${3:?platform required}
[[ "$build_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]
[[ "$platform" =~ ^linux/(amd64|arm64)$ ]]
# Even `go version` can write telemetry/config. Keep all build-time probes out
# of the image user's HOME before invoking any inherited SDK or provider.
scratch=$(mktemp -d /opt/multica/.finalize.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -m 0700 "$scratch/home" "$scratch/tmp"
export HOME="$scratch/home" TMPDIR="$scratch/tmp"
contract=/opt/multica/controller/build.json
jq -e --arg platform "$platform" '
  .schemaVersion == 2 and .controllerABI == 2 and .platform == $platform and
  (.runtimeSHA256 | test("^[a-f0-9]{64}$")) and (.buildID | test("^[a-f0-9]{64}$"))' "$contract" >/dev/null
controller_path=$(jq -er .runtimePath "$contract")
[[ "$(sha256sum "$controller_path" | awk '{print $1}')" == "$(jq -er .runtimeSHA256 "$contract")" ]]
[[ "$(go version | awk '{print $3}')" == "$(jq -er .goVersion "$contract")" ]]
[[ "$(stat -c %u /opt /opt/multica /home /home/multica | sort -u)" == 0 ]]
for parent in /opt /opt/multica /home /home/multica; do
  permissions=$(stat -c %a "$parent")
  (( (8#$permissions & 0022) == 0 ))
done

tool_path=$(jq -er '.binDirs | join(":")' "$root/build/layout.json")
[[ "$PATH" == "$tool_path" ]] || { echo 'Image ENV PATH differs from the controller tool paths' >&2; exit 1; }
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
  jq '. + {adapterContract:"multica-v0.4.40-v1"}' > "$scratch/daemon.json"
# The contract names the adapter baseline, not an unconditional version allowlist.
# A new CLI pin must pass the actual matching-source suite before finalization.
printf '{}\n' > "$scratch/providers.json"
for provider in codex pi; do
  key=$(tr '[:lower:]' '[:upper:]' <<< "$provider")_VERSION
  metadata "$(jq -er --arg provider "$provider" '.providers[$provider]' "$root/build/layout.json")" "$(get_pin "$key")" > "$scratch/provider.json"
  jq --arg name "$provider" --slurpfile provider "$scratch/provider.json" '. + {($name):$provider[0]}' "$scratch/providers.json" > "$scratch/next.json"
  mv "$scratch/next.json" "$scratch/providers.json"
done
seed=$(jq -er .homeSeed "$root/build/layout.json")
[[ "$seed" == /opt/multica/runtime/home-seed && -d "$seed" ]]
# Controller admission validates seed confinement, including npm command links.
if find "$seed" -type b -o -type c -o -type p -o -type s | grep -q .; then
  echo 'Image home seed contains unsupported entries' >&2; exit 1
fi
mkdir -p /opt/multica/runtime
# Installation stages consume subsets; provenance retains the exact public input.
mkdir -p /opt/multica/runtime/inventory
cp "$root/versions.env" /opt/multica/runtime/inventory/versions.env
jq -n --arg id "$build_id" --arg platform "$platform" \
  --slurpfile controller "$contract" --slurpfile daemon "$scratch/daemon.json" \
  --slurpfile providers "$scratch/providers.json" --slurpfile layout "$root/build/layout.json" '
  {schemaVersion:1,kind:"multica-runtime-image",imageBuildID:$id,platform:$platform,
   controller:$controller[0],daemon:$daemon[0],providers:$providers[0],
   binDirs:$layout[0].binDirs,env:$layout[0].env,homeSeed:$layout[0].homeSeed}' \
  > /opt/multica/runtime/image.json
chmod 0444 /opt/multica/runtime/image.json

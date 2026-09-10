#!/bin/bash
# Runs inside the image with a controller-initialized HOME and private tmp/run mounts.
set -euo pipefail
[[ $# == 0 ]] || { echo 'Usage: verify-native.sh' >&2; exit 2; }
umask 077
[[ $(id -u) == 65532 && $(id -g) == 65532 ]] || { echo 'Verification requires UID/GID 65532' >&2; exit 1; }
descriptor=/opt/multica/runtime/image.json
inventory=/opt/multica/runtime/inventory
for directory in "$HOME" /tmp /run/multica; do
  [[ -d "$directory" && -O "$directory" ]]
  mode=$(stat -c %a "$directory")
  (( (8#$mode & 0777) == 0700 ))
done
for parent in / /home /home/multica /run; do
  [[ $(stat -c %u "$parent") == 0 ]]
  mode=$(stat -c %a "$parent")
  (( (8#$mode & 0022) == 0 ))
done
scratch=$(mktemp -d /tmp/runtime-native.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
# Prepare environment variables for direct tool probes.
while IFS= read -r -d '' key && IFS= read -r -d '' value; do export "$key=$value"; done < <(
  jq -j --arg home "$HOME" --arg temporary /tmp --arg workspace /workspace '
    .env | to_entries[] | .key, "\u0000", (.value | split("${HOME}") | join($home) |
      split("${TMPDIR}") | join($temporary) | split("${WORKSPACE}") | join($workspace)), "\u0000"' "$descriptor"
)
# Match runtimeimage.Vars trusted Locations; HOME/TMPDIR cannot be overridden by
# descriptor Env. All descriptor values use the same three interpolation inputs.
export TMPDIR=/tmp
tool_path=$(jq -r '.binDirs[]' "$descriptor" | while IFS= read -r directory; do readlink -f "$directory"; done | paste -sd: -)
export PATH="$tool_path"
pin() { sed -n "s/^$1=//p" "$inventory/versions.env"; }
probe() {
  local name=$1 expected=$2
  shift 2
  timeout 90 "$@" > "$scratch/probe" 2>&1 || { cat "$scratch/probe" >&2; echo "Tool execution failed: $name" >&2; return 1; }
  grep -F -- "$expected" "$scratch/probe" >/dev/null || { echo "Tool version mismatch: $name" >&2; cat "$scratch/probe" >&2; return 1; }
  printf '%s\t%s\n' "$name" "$(grep -Fm1 -- "$expected" "$scratch/probe")"
}
probe go "$(jq -r .controller.goVersion "$descriptor")" go version
probe multica "$(pin MULTICA_CLI_VERSION)" multica --version
probe node "$(pin NODE_VERSION)" node --version
probe corepack "$(pin COREPACK_VERSION)" corepack --version
probe php "$(pin PHP_VERSION)" php --version
probe composer "$(pin COMPOSER_VERSION)" composer --version
probe rustc "$(pin RUST_VERSION)" rustc --version
probe cargo "$(pin RUST_VERSION)" cargo --version
probe python "$(pin PYTHON_VERSION)" python --version
probe uv "$(pin UV_VERSION)" uv --version
probe pipx "$(pin PIPX_VERSION)" pipx --version
probe git 'git version' git --version
probe git-lfs git-lfs git lfs version
probe git-flow AVH git flow version
probe gh "$(pin GH_VERSION)" gh --version
probe curl curl curl --version
probe grep grep grep --version
probe coreutils 'GNU coreutils' cp --version
probe vim VIM vim --version
probe tree tree tree --version
probe lefthook "$(pin LEFTHOOK_VERSION)" lefthook version
probe jq jq jq --version
probe yq "$(pin YQ_VERSION)" yq --version
probe shellcheck ShellCheck shellcheck --version
probe shfmt "$(pin SHFMT_VERSION)" shfmt --version
probe ffmpeg ffmpeg ffmpeg -version
probe imagemagick ImageMagick convert -version
probe poppler pdftotext pdftotext -v
probe pandoc pandoc pandoc --version
probe k9s "$(pin K9S_VERSION)" k9s version -s
probe kubectx "$(pin KUBECTX_VERSION)" kubectx --version
probe kubectl "$(pin KUBECTL_VERSION)" kubectl version --client=true --output=json
probe aws "$(pin AWS_CLI_VERSION)" aws --version
probe oci "$(pin OCI_CLI_VERSION)" oci --version
probe gcloud "$(pin GCLOUD_CLI_VERSION)" gcloud version
probe codex "$(pin CODEX_VERSION)" codex --version
probe pi "$(pin PI_VERSION)" pi --version
probe codebase-memory-mcp "$(pin CODEBASE_MEMORY_MCP_VERSION)" codebase-memory-mcp --version
probe chrome-devtools-mcp "$(pin CHROME_DEVTOOLS_MCP_VERSION)" chrome-devtools-mcp --version
for extension in mongodb redis zstd; do php --ri "$extension" > "$scratch/php-$extension"; done
[[ $(php -r 'echo phpversion("mongodb");') == "$(pin MONGODB_PHP_EXTENSION_VERSION)" ]]
[[ $(php -r 'echo phpversion("redis");') == "$(pin PHPREDIS_VERSION)" ]]
[[ $(php -r 'echo phpversion("zstd");') == "$(pin ZSTD_PHP_EXTENSION_VERSION)" ]]
# shellcheck disable=SC2016
php -r '
  $value = ["fixture" => "runtime", "count" => 7];
  if ((array) MongoDB\BSON\Document::fromPHP($value)->toPHP() !== $value) exit(1);
  $redis = new Redis();
  $redis->setOption(Redis::OPT_SERIALIZER, Redis::SERIALIZER_PHP);
  if ($redis->_unserialize($redis->_serialize($value)) !== $value) exit(2);
  if (zstd_uncompress(zstd_compress("runtime-fixture")) !== "runtime-fixture") exit(3);
'
printf 'fn main() { println!("rust-native-ok"); }\n' > "$scratch/main.rs"
rustc "$scratch/main.rs" -o "$scratch/rust-fixture"
[[ $("$scratch/rust-fixture") == rust-native-ok ]]
printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("go-native-ok") }\n' > "$scratch/main.go"
go build -o "$scratch/go-fixture" "$scratch/main.go"
[[ $("$scratch/go-fixture") == go-native-ok ]]
python3 -m venv "$scratch/python-venv"
"$scratch/python-venv/bin/python" -c 'import json, sqlite3, ssl; c=sqlite3.connect(":memory:"); assert c.execute("select 6*7").fetchone()[0] == 42; assert json.loads("{\"ok\":true}")["ok"]'
node -e 'const fs=require("node:fs"); fs.writeFileSync(process.env.HOME+"/node-fixture", "ok"); if(fs.readFileSync(process.env.HOME+"/node-fixture", "utf8")!=="ok") process.exit(1)'
codebase-memory-mcp config get auto_index > "$scratch/cbm-config"
grep -F true "$scratch/cbm-config" >/dev/null
[[ ! -w /opt/multica/tools && ! -w /opt/multica/controller/runtime ]]
echo 'Fresh HOME, actual tool execution, PHP extension APIs, Rust/Go compilation and Python venv passed'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/verify-providers.sh"

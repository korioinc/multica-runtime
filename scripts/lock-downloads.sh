#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
runtime_versions_env > "$scratch/versions.env"
while IFS='=' read -r key value; do export "$key=$value"; done < "$scratch/versions.env"
runtime_versions_json > "$scratch/versions.json"
fetch() { curl --fail --location --silent --show-error --retry 3 --connect-timeout 30 --max-time 1200 "$1" --output "$2"; }
artifact() {
  local name=$1 url=$2 checksum=${3:-}
  if [[ -z "$checksum" ]]; then
    fetch "$url" "$scratch/download"
    checksum=$(shasum -a 256 "$scratch/download" | awk '{print $1}')
  fi
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]]
  jq --arg name "$name" --arg url "$url" --arg sha "$checksum" '. + {($name):{url:$url,sha256:$sha}}' "$scratch/artifacts.json" > "$scratch/next.json"
  mv "$scratch/next.json" "$scratch/artifacts.json"
}
github_asset() {
  local name=$1 repository=$2 filename=$3 entry url checksum
  entry=$(jq -ce --arg name "$filename" '.assets[] | select(.name==$name)' "$scratch/$repository.json")
  url=$(jq -er .browser_download_url <<< "$entry")
  checksum=$(jq -r '.digest // "" | sub("^sha256:";"")' <<< "$entry")
  artifact "$name" "$url" "$checksum"
}
while IFS='|' read -r name repository version; do
  fetch "https://api.github.com/repos/$repository/releases/tags/$version" "$scratch/$name.json"
done <<RELEASES
multica|multica-ai/multica|v$MULTICA_CLI_VERSION
gh|cli/cli|v$GH_VERSION
k9s|derailed/k9s|v$K9S_VERSION
kubectx|ahmetb/kubectx|v$KUBECTX_VERSION
yq|mikefarah/yq|v$YQ_VERSION
shfmt|mvdan/sh|v$SHFMT_VERSION
lefthook|evilmartians/lefthook|v$LEFTHOOK_VERSION
uv|astral-sh/uv|$UV_VERSION
cbm|DeusData/codebase-memory-mcp|v$CODEBASE_MEMORY_MCP_VERSION
RELEASES
printf '{}\n' > "$scratch/artifacts.json"
artifact php "https://www.php.net/distributions/php-$PHP_VERSION.tar.xz"
artifact composer "https://getcomposer.org/download/$COMPOSER_VERSION/composer.phar"
artifact mongodb "https://pecl.php.net/get/mongodb-$MONGODB_PHP_EXTENSION_VERSION.tgz"
artifact redis "https://pecl.php.net/get/redis-$PHPREDIS_VERSION.tgz"
artifact zstd "https://pecl.php.net/get/zstd-$ZSTD_PHP_EXTENSION_VERSION.tgz"
cp "$scratch/artifacts.json" "$scratch/common.json"
fetch "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" "$scratch/node-checksums"
for arch in amd64 arm64; do
  if [[ "$arch" == amd64 ]]; then cpu=x86_64; node_arch=x64; kctx=x86_64; google=x86_64; else cpu=aarch64; node_arch=arm64; kctx=arm64; google=arm; fi
  cp "$scratch/common.json" "$scratch/artifacts.json"
  filename="node-v$NODE_VERSION-linux-$node_arch.tar.xz"
  checksum=$(awk -v name="$filename" '$2==name {print $1}' "$scratch/node-checksums")
  [[ -n "$checksum" ]]
  artifact node "https://nodejs.org/dist/v$NODE_VERSION/$filename" "$checksum"
  url="https://static.rust-lang.org/dist/rust-$RUST_VERSION-$cpu-unknown-linux-gnu.tar.xz"
  fetch "$url.sha256" "$scratch/checksum"; artifact rust "$url" "$(awk 'NR==1 {print $1}' "$scratch/checksum")"
  url="https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/linux/$arch/kubectl"
  fetch "$url.sha256" "$scratch/checksum"; artifact kubectl "$url" "$(tr -d '\n' < "$scratch/checksum")"
  github_asset multica multica "multica-cli-$MULTICA_CLI_VERSION-linux-$arch.tar.gz"
  github_asset gh gh "gh_${GH_VERSION}_linux_$arch.tar.gz"
  github_asset k9s k9s "k9s_Linux_$arch.tar.gz"
  github_asset kubectx kubectx "kubectx_v${KUBECTX_VERSION}_linux_$kctx.tar.gz"
  github_asset kubens kubectx "kubens_v${KUBECTX_VERSION}_linux_$kctx.tar.gz"
  github_asset yq yq "yq_linux_$arch"
  github_asset shfmt shfmt "shfmt_v${SHFMT_VERSION}_linux_$arch"
  github_asset lefthook lefthook "lefthook_${LEFTHOOK_VERSION}_Linux_$kctx"
  github_asset uv uv "uv-$cpu-unknown-linux-gnu.tar.gz"
  github_asset cbm cbm "codebase-memory-mcp-linux-$arch-portable.tar.gz"
  artifact aws "https://awscli.amazonaws.com/awscli-exe-linux-$cpu-$AWS_CLI_VERSION.zip"
  artifact gcloud "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-$GCLOUD_CLI_VERSION-linux-$google.tar.gz"
  jq -n --arg platform "linux/$arch" --slurpfile versions "$scratch/versions.json" --slurpfile artifacts "$scratch/artifacts.json" \
    '{schemaVersion:1,platform:$platform,versions:$versions[0],artifacts:$artifacts[0]}' > "$runtime_root/locks/downloads-$arch.json"
  echo "Locked release downloads for linux/$arch"
done

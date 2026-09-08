#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
case "${1:-}" in
  --refresh)
    runtime_npm_manifests
    for group in providers pi-packages; do
      npm install --package-lock-only --ignore-scripts --no-audit --no-fund --prefix "$runtime_root/build/npm/$group"
    done ;;
  --complete-integrity) ;;
  *) echo 'Usage: lock-npm.sh --refresh|--complete-integrity' >&2; exit 2 ;;
esac
# npm may omit integrity for packages nested in a published shrinkwrap. Pin their
# exact recorded tarball bytes as well; never resolve a floating package here.
for group in providers pi-packages; do
  lock="$runtime_root/build/npm/$group/package-lock.json"
  cp "$lock" "$scratch/lock.json"
  while IFS=$'\t' read -r key url; do
    [[ "$url" == https://registry.npmjs.org/* ]]
    curl --fail --location --silent --show-error --retry 3 "$url" --output "$scratch/package.tgz"
    integrity="sha512-$(openssl dgst -sha512 -binary "$scratch/package.tgz" | openssl base64 -A)"
    jq --arg key "$key" --arg integrity "$integrity" '.packages[$key].integrity = $integrity' "$scratch/lock.json" > "$scratch/next.json"
    mv "$scratch/next.json" "$scratch/lock.json"
  done < <(jq -r '.packages | to_entries[] | select(.key != "" and .value.integrity == null) | [.key,.value.resolved] | @tsv' "$lock")
  cp "$scratch/lock.json" "$lock"
done
echo 'npm direct versions and transitive tarball integrity locked'

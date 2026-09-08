#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
resolver_image=
arch=
while (($#)); do
  case "$1" in
    --resolver-image) resolver_image=$2; shift 2 ;;
    --arch) arch=$2; shift 2 ;;
    *) echo 'Usage: lock-apt.sh --resolver-image IMAGE@sha256:DIGEST --arch amd64|arm64' >&2; exit 2 ;;
  esac
done
[[ "$resolver_image" == *@sha256:* && "$arch" =~ ^(amd64|arm64)$ ]] || exit 2
inputs=$(runtime_versions_json)
snapshot=$(jq -er .DEBIAN_SNAPSHOT <<< "$inputs")
codename=$(jq -er .DEBIAN_CODENAME <<< "$inputs")
result=$(mktemp)
trap 'rm -f "$result"' EXIT
docker run --rm --platform "linux/$arch" --user 0 \
  --mount "type=bind,src=$runtime_root/build,dst=/input,readonly" \
  -e "SNAPSHOT=$snapshot" -e "CODENAME=$codename" "$resolver_image" sh -ec '
rm -f /etc/apt/sources.list.d/*
printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s/ %s main\n" "$SNAPSHOT" "$CODENAME" > /etc/apt/sources.list
printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s/ %s-updates main\n" "$SNAPSHOT" "$CODENAME" >> /etc/apt/sources.list
printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/%s/ %s-security main\n" "$SNAPSHOT" "$CODENAME" >> /etc/apt/sources.list
apt-get update -qq >&2
while IFS= read -r package; do
  version=$(apt-cache madison "$package" | awk "NR == 1 {print \$3}")
  test -n "$version" || { echo "No snapshot candidate: $package" >&2; exit 1; }
  printf "%s=%s\n" "$package" "$version"
done < /input/apt-packages.txt
' > "$result"
chmod 0644 "$result"
mv "$result" "$runtime_root/locks/apt-$arch.lock"
echo "Locked Debian packages for linux/$arch; package resolution is not native execution proof"

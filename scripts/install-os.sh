#!/bin/sh
set -eu
arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64) ;; *) echo 'Unsupported image architecture' >&2; exit 1 ;; esac
# The base deliberately has no Python requirement. Read only these validated
# literal keys using shell builtins; no source/eval or arbitrary exports.
snapshot=
codename=
while IFS='=' read -r key value; do
  case "$key" in
    DEBIAN_SNAPSHOT) snapshot=$value ;;
    DEBIAN_CODENAME) codename=$value ;;
  esac
done < /build-input/versions.env
case "$snapshot" in ????????T??????Z) ;; *) exit 1 ;; esac
case "$snapshot" in *[!0-9TZ]*) exit 1 ;; esac
test "$codename" = bookworm
rm -f /etc/apt/apt.conf.d/docker-clean
printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/keep-build-downloads
rm -f /etc/apt/sources.list.d/*
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s/ %s main\n' "$snapshot" "$codename" > /etc/apt/sources.list
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s/ %s-updates main\n' "$snapshot" "$codename" >> /etc/apt/sources.list
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/%s/ %s-security main\n' "$snapshot" "$codename" >> /etc/apt/sources.list
apt-get update
set --
while IFS= read -r item; do
  set -- "$@" "$item"
done < "/build-input/locks/apt-$arch.lock"
DEBIAN_FRONTEND=noninteractive apt-get install --yes --allow-downgrades --no-install-recommends "$@"
for item do
  package=${item%%=*}
  expected=${item#*=}
  actual=$(dpkg-query -W -f='${Version}' "$package")
  test "$actual" = "$expected" || { echo "OS lock mismatch: $package" >&2; exit 1; }
done
mkdir -p /opt/multica/runtime/inventory
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /opt/multica/runtime/inventory/debian.tsv
cp "/build-input/locks/apt-$arch.lock" /opt/multica/runtime/inventory/apt.lock
chmod 0444 /opt/multica/runtime/inventory/apt.lock
# These directories are BuildKit cache mounts; they are absent from final layers.
rm -f /etc/apt/apt.conf.d/keep-build-downloads

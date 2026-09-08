#!/bin/sh
set -eu

# --- Debian installation inputs ---
# Validate the target architecture and pinned Debian snapshot settings.
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

# --- APT repositories and cache ---
# Use a fixed Debian snapshot and cache packages downloaded during the build.
rm -f /etc/apt/apt.conf.d/docker-clean
printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/keep-build-downloads
rm -f /etc/apt/sources.list.d/*
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s/ %s main\n' "$snapshot" "$codename" > /etc/apt/sources.list
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s/ %s-updates main\n' "$snapshot" "$codename" >> /etc/apt/sources.list
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/%s/ %s-security main\n' "$snapshot" "$codename" >> /etc/apt/sources.list
apt-get update

# --- OS packages ---
# Install tools from build/apt-packages.txt and resolve dependencies from the Debian snapshot.
# Languages/build: Python 3, pip, venv, pipx, C/C++ build tools, and development libraries for PHP extensions.
# Development/shell: Git/Git LFS/git-flow, SSH, curl, jq, ShellCheck, Vim, and archive/file utilities.
# Documents/media: Pandoc, Poppler, ImageMagick, FFmpeg.
set --
while IFS= read -r item || [ -n "$item" ]; do
  case "$item" in
    ''|\#*) continue ;;
    *[!a-z0-9+.-]*|-*|.*|+*) echo "Invalid Debian package name: $item" >&2; exit 1 ;;
  esac
  set -- "$@" "$item"
done < /build-input/build/apt-packages.txt
[ "$#" -gt 0 ] || { echo 'No Debian packages configured' >&2; exit 1; }
DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "$@"

# --- Installed package inventory ---
# Record the packages actually installed in the image.
mkdir -p /opt/multica/runtime/inventory
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /opt/multica/runtime/inventory/debian.tsv

# --- Build-time APT configuration cleanup ---
# These directories are BuildKit cache mounts; they are absent from final layers.
rm -f /etc/apt/apt.conf.d/keep-build-downloads

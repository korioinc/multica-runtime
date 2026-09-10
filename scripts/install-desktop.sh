#!/bin/bash
set -euo pipefail
# shellcheck source=install-common.sh
source /build-input/scripts/install-common.sh desktop

# Reuse the pinned Debian repositories from install-os.sh, after language builds
# and before frequently updated agent packages.
build_home=$(mktemp -d /opt/multica/.desktop-home.XXXXXX)
trap 'rm -rf -- "$scratch" "$build_home"' EXIT HUP INT TERM
export HOME="$build_home"
rm -f /etc/apt/apt.conf.d/docker-clean
apt-get update
packages=()
while IFS= read -r item || [[ -n "$item" ]]; do
  [[ "$item" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { echo 'Invalid desktop package name' >&2; exit 1; }
  packages+=("$item")
done < /build-input/build/desktop-apt-packages.txt

# Official Google Chrome is available for both supported Linux architectures.
# Use the versioned official package URL and validate its package metadata.
chrome_package=$(basename -- "$(download_url google-chrome "$arch")")
download google-chrome "$scratch/$chrome_package"
[[ $(dpkg-deb --field "$scratch/$chrome_package" Package) == google-chrome-stable ]]
[[ $(dpkg-deb --field "$scratch/$chrome_package" Version) == "$GOOGLE_CHROME_VERSION" ]]
[[ $(dpkg-deb --field "$scratch/$chrome_package" Architecture) == "$arch" ]]
# Keep updates under image rebuilds; disable Google's automatic repository setup.
mkdir -p /etc/default
printf 'repo_add_once="false"\nrepo_reenable_on_distupgrade="false"\n' > /etc/default/google-chrome
DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "${packages[@]}" "$scratch/$chrome_package"
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /opt/multica/runtime/inventory/debian.tsv

# Install the official pinned CLI and its companion cursor tool outside HOME.
# Do not run the interactive installer, skills install, or MCP registration.
archive=$(basename -- "$(download_url cua-driver "$arch")")
download cua-driver "$scratch/$archive"
tar -xzf "$scratch/$archive" -C "$scratch" cua-driver cua-cursor-theme
mkdir -p "$tools/cua-driver"
install -m 0555 "$scratch/cua-driver" "$scratch/cua-cursor-theme" "$tools/cua-driver/"
"$tools/cua-driver/cua-driver" --version
"$tools/cua-driver/cua-cursor-theme" list --json
google-chrome-stable --version
ln -s ../cua-driver/cua-driver "$tools/bin/cua-driver"
ln -s ../cua-driver/cua-cursor-theme "$tools/bin/cua-cursor-theme"
chmod 0555 "$tools/cua-driver"

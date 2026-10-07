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

# Open Browser Use: the same pinned binary serves the CLI and Chrome native host.
download open-browser-use "$scratch/open-browser-use.tar.gz"
tar -xzf "$scratch/open-browser-use.tar.gz" -C "$tools/bin" open-browser-use
chmod 0555 "$tools/bin/open-browser-use"
ln -s open-browser-use "$tools/bin/obu"
[[ $("$tools/bin/obu" version) == "$OPEN_BROWSER_USE_VERSION" ]]

# Cua Driver's native CLI/MCP runtime uses X11 and AT-SPI directly.
# Keep its cursor-theme companion beside the CLI; SDK bindings are not needed.
download cua-driver "$scratch/cua-driver.tar.gz"
tar -xzf "$scratch/cua-driver.tar.gz" -C "$tools/bin" cua-driver cua-cursor-theme
chmod 0555 "$tools/bin/cua-driver" "$tools/bin/cua-cursor-theme"
[[ $("$tools/bin/cua-driver" --version) == "cua-driver $CUA_DRIVER_VERSION" ]]
# Upstream binary archives omit the license; retain the matching release notice.
download cua-driver-license "$scratch/cua-driver-LICENSE"
install -Dm 0444 "$scratch/cua-driver-LICENSE" /usr/share/doc/cua-driver/LICENSE

#!/bin/bash
set -euo pipefail
# shellcheck source=install-common.sh
source /build-input/scripts/install-common.sh languages

# --- Node.js / npm ---
# Install the JavaScript runtime and its bundled npm package manager.
download node "$scratch/node.tar.xz"
mkdir -p "$tools/node"
tar -xJf "$scratch/node.tar.xz" --strip-components=1 -C "$tools/node"

# --- PHP ---
# Build PHP CLI with string, internationalization, compression, and MySQL/PostgreSQL extensions.
download php "$scratch/php.tar.xz"
mkdir "$scratch/php"
tar -xJf "$scratch/php.tar.xz" --strip-components=1 -C "$scratch/php"
(
  cd "$scratch/php"
  ./configure --prefix="$tools/php" \
    --with-config-file-path="$tools/php/etc" --with-config-file-scan-dir="$tools/php/etc/conf.d" \
    --disable-cgi --disable-phpdbg --without-pear \
    --enable-bcmath --enable-mbstring --enable-intl --enable-pcntl --enable-sockets \
    --with-curl --with-openssl --with-zlib --with-zip --with-readline \
    --with-pdo-mysql --with-pdo-pgsql --with-mysqli --with-gmp --with-bz2 --with-xsl
  make -j "${BUILD_JOBS:-4}"
  make install
  mkdir -p "$tools/php/etc/conf.d"
  cp php.ini-development "$tools/php/etc/php.ini"
)

# --- Additional PHP extensions ---
# Build MongoDB, Redis, and Zstandard extensions and enable them through PHP ini files.
for extension in mongodb redis zstd; do
  download "$extension" "$scratch/$extension.tgz"
  mkdir "$scratch/$extension"
  tar -xzf "$scratch/$extension.tgz" --strip-components=1 -C "$scratch/$extension"
  (
    cd "$scratch/$extension"
    "$tools/php/bin/phpize"
    ./configure --with-php-config="$tools/php/bin/php-config"
    make -j "${BUILD_JOBS:-4}"
    make install
  )
  printf 'extension=%s.so\n' "$extension" > "$tools/php/etc/conf.d/$extension.ini"
done

# --- Composer ---
# Install the dependency manager for PHP projects.
download composer "$tools/bin/composer"
chmod 0555 "$tools/bin/composer"

# --- Rust / Cargo ---
# Install the Rust compiler, Cargo, and bundled tools, excluding rust-docs.
download rust "$scratch/rust.tar.xz"
mkdir "$scratch/rust"
tar -xJf "$scratch/rust.tar.xz" --strip-components=1 -C "$scratch/rust"
"$scratch/rust/install.sh" --prefix="$tools/rust" --without=rust-docs --disable-ldconfig

# --- Python / pipx version checks ---
# Verify the pinned versions of Python and pipx installed as Debian packages by install-os.sh.
[[ "$(python3 -c 'import platform; print(platform.python_version())')" == "$PYTHON_VERSION" ]]
[[ "$(pipx --version)" == "$PIPX_VERSION" ]]

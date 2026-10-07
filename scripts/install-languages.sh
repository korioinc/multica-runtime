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

# --- Python / pip ---
# Build the selected release without replacing Debian's /usr/bin/python3.
download python "$scratch/python.tar.xz"
mkdir "$scratch/python"
tar -xJf "$scratch/python.tar.xz" --strip-components=1 -C "$scratch/python"
(
  cd "$scratch/python"
  ./configure --prefix="$tools/python" --with-ensurepip=install --disable-test-modules
  make -j "${BUILD_JOBS:-4}"
  make install
)
for executable in python3 pip3; do
  ln -sf "../python/bin/$executable" "$tools/bin/$executable"
done
ln -sf python3 "$tools/bin/python"
ln -sf pip3 "$tools/bin/pip"
# python3-config derives its prefix from its invoked path, so use an exec wrapper.
printf '#!/bin/sh\nexec /opt/multica/tools/python/bin/python3-config "$@"\n' > "$tools/bin/python3-config"
chmod 0555 "$tools/bin/python3-config"

# Fail the build if the selected runtime or essential native modules are missing.
"$tools/bin/python3" -c 'import _uuid, bz2, ctypes, dbm.ndbm, lzma, platform, readline, sqlite3, ssl, zlib; import os; assert platform.python_version() == os.environ["PYTHON_VERSION"]'

# Set permissions in this layer so later installers do not copy up language files.
find "$tools" \( -type f -o -type d \) -perm /222 -exec chmod a-w {} +

#!/bin/bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

database_inputs=$(runtime_versions_env database)
while IFS='=' read -r key value; do export "$key=$value"; done <<< "$database_inputs"
postgres_version=${POSTGRESQL_CLI_VERSION#*:}
postgres_major=${postgres_version%%.*}
[[ "$postgres_major" =~ ^[1-9][0-9]+$ ]] || { echo 'PostgreSQL client pins require major 10 or newer' >&2; exit 1; }

# Use the snapshot repositories configured by install-os.sh. Keep client-only
# additions after language/desktop installation so they preserve those caches.
# Pin the implementation packages: metapackage versions do not pin CLI binaries.
# mysql itself belongs to mariadb-client-core, which mariadb-client only bounds below.
packages=(
  "mariadb-client=$MYSQL_CLI_VERSION"
  "mariadb-client-core=$MYSQL_CLI_VERSION"
  "postgresql-client-$postgres_major=$POSTGRESQL_CLI_VERSION"
  "sqlite3=$SQLITE_CLI_VERSION"
  "redis-tools=$REDIS_CLI_VERSION"
)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "${packages[@]}"
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /opt/multica/runtime/inventory/debian.tsv

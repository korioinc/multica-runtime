#!/bin/bash
# Keep each installation cache dependent only on the versions it consumes.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
destination=${1:?projected input destination required}
# Reject incomplete public inputs before publishing any installation inputs.
runtime_versions_env >/dev/null
for scope in os languages tools desktop database agents; do
  mkdir -p "$destination/$scope"
  runtime_versions_env "$scope" > "$destination/$scope/versions.env"
done

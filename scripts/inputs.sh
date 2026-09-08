#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
case "${1:-}" in
  json) runtime_versions_json ;;
  env) runtime_versions_env ;;
  npm-manifest) runtime_npm_manifest "${2:-}" ;;
  check) runtime_check_inputs "${2:-}"; echo 'Build inputs are valid' ;;
  *) echo 'Usage: inputs.sh json|env|npm-manifest GROUP|check [--production]' >&2; exit 2 ;;
esac

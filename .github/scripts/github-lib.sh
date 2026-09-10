#!/usr/bin/env bash
# Shared command diagnostics and GitHub source identity for release automation.
# Callers provide scratch, release_command, fail(), and GH_REPO for GitHub calls.
: "${scratch:?}" "${release_command:?}"

capture_command() { "$@" >"$scratch/stdout" 2>"$scratch/stderr"; }

command_failure() {
  local operation=$1 code=$2 stream
  printf 'release blocked: %s: %s (command exit %s)\n' "$release_command" "$operation" "$code" >&2
  for stream in stdout stderr; do
    if [[ -s $scratch/$stream ]]; then
      printf '%s:\n' "$stream" >&2
      cat "$scratch/$stream" >&2 || true
      printf '\n' >&2
    fi
  done
  # A command can commit a remote write and still fail before acknowledging it.
  printf 'Completed steps may persist; inspect remote state before retrying.\n' >&2
  exit 1
}

run_command() {
  local operation=$1
  shift
  capture_command "$@" || command_failure "$operation failed" "$?"
  cat "$scratch/stdout" || fail 'cannot read command output'
}

github() {
  local response header body status code operation="GitHub lookup $1"
  if capture_command gh api --include "repos/$GH_REPO/$1"; then code=0; else code=$?; fi
  response=$(cat "$scratch/stdout") || fail 'cannot read GitHub response'
  response=${response//$'\r'/}
  [[ $response == *$'\n\n'* ]] || command_failure "$operation returned an unreadable response" "$code"
  header=${response%%$'\n\n'*} body=${response#*$'\n\n'}
  [[ $header =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]] || command_failure "$operation returned an unreadable response" "$code"
  status=${BASH_REMATCH[1]}
  if [[ $status == 404 ]]; then printf 'null\n'; return; fi
  [[ $status == 200 && $code == 0 ]] || command_failure "$operation failed (HTTP $status)" "$code"
  jq -ce 'if type == "object" then . else error("invalid GitHub object") end' <<<"$body" ||
    command_failure "$operation returned an invalid object" "$code"
}

github_tag_revision() {
  local requested_version=$1 require_tag=${2:-false} tag target sha nested visited=' '
  tag=$(github "git/ref/tags/$requested_version") || return 1
  [[ $require_tag != true || $tag != null ]] || fail 'pushed release tag is missing'
  if [[ $tag == null ]]; then return; fi
  target=$(jq -c '.object' <<<"$tag") || fail 'invalid release tag'
  while [[ $(jq -r '.type' <<<"$target") == tag ]]; do
    sha=$(jq -r '.sha' <<<"$target") || fail 'invalid annotated release tag'
    [[ $sha =~ ^[0-9a-f]{40}$ && $visited != *" $sha "* ]] || fail 'invalid annotated release tag'
    visited="$visited$sha "
    nested=$(github "git/tags/$sha") || return 1
    target=$(jq -c '.object' <<<"$nested") || fail 'invalid annotated release tag'
  done
  jq -e '.type == "commit" and (.sha | type == "string" and test("^[0-9a-f]{40}$"))' <<<"$target" >/dev/null ||
    fail 'invalid release tag target'
  jq -r '.sha' <<<"$target"
}

github_require_main_revision() {
  local revision=$1 main main_revision comparison
  main=$(github git/ref/heads/main) || return 1
  main_revision=$(jq -r '.object.sha // ""' <<<"$main") || fail 'invalid main revision'
  [[ $main_revision =~ ^[0-9a-f]{40}$ ]] || fail 'main must identify a commit'
  comparison=$(github "compare/$revision...$main_revision") || return 1
  jq -e '.status == "ahead" or .status == "identical"' <<<"$comparison" >/dev/null ||
    fail 'release revision is not in main history'
}

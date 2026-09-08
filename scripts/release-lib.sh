#!/usr/bin/env bash
# Independent runtime version ordering; never reads the controller's VERSION.
version_error() { printf 'runtime version error: %s\n' "$*" >&2; return 1; }
version_stable() {
  [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || version_error 'expected stable semantic version'
}
version_read() {
  local value
  value=$(cat -- "$1") || return 1
  [[ $(wc -l < "$1") -eq 1 ]] || { version_error 'VERSION must contain one newline-terminated value'; return 1; }
  version_stable "$value" || return 1
  printf '%s\n' "$value"
}
version_compare() {
  local left right index
  local -a left_parts right_parts
  version_stable "$1" && version_stable "$2" || return 1
  IFS=. read -r -a left_parts <<< "$1"
  IFS=. read -r -a right_parts <<< "$2"
  for index in 0 1 2; do
    left=${left_parts[index]} right=${right_parts[index]}
    if [[ ${#left} -gt ${#right} || (${#left} -eq ${#right} && $left > $right) ]]; then printf '1\n'; return; fi
    if [[ ${#left} -lt ${#right} || (${#left} -eq ${#right} && $left < $right) ]]; then printf '%s\n' -1; return; fi
  done
  printf '0\n'
}
version_github_output() {
  [[ -n ${GITHUB_OUTPUT:-} ]] || { version_error 'GITHUB_OUTPUT required'; return 1; }
  jq -er 'to_entries[] | if (.value | tostring | test("[\r\n]")) then error("multiline output") else "\(.key)=\(.value)" end' <<< "$1" >> "$GITHUB_OUTPUT"
}

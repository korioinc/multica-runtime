#!/usr/bin/env bash
# Exercise committed VERSION releases against real Git history and a local GitHub stub.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
checkout="$scratch/checkout"
export TAG_FIXTURE_STATE="$scratch/state"
export TAG_FIXTURE_CHECKOUT="$checkout"
export GH_REPO=fixture/runtime
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$scratch/bin" "$checkout"
export PATH="$scratch/bin:$PATH"
cat > "$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state=$TAG_FIXTURE_STATE
[[ $1 == api ]]
shift
method=GET
endpoint=''
input=''
include=false
while (($#)); do
  case "$1" in
    --include) include=true; shift ;;
    --method) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    repos/*) endpoint=${1#repos/fixture/runtime/}; shift ;;
    *) exit 2 ;;
  esac
done
respond() {
  local status=$1 body=$2
  if [[ $include == true ]]; then printf 'HTTP/1.1 %s\r\n\r\n' "$status"; fi
  printf '%s\n' "$body"
  [[ $status == 2* ]]
}
if [[ $method == GET ]]; then
  case "$endpoint" in
    git/ref/heads/main)
      respond '200 OK' "$(jq -n --arg revision "$(cat "$state/main")" '{object:{type:"commit",sha:$revision}}')"
      exit ;;
    compare/*)
      revisions=${endpoint#compare/}
      base=${revisions%%...*} head=${revisions#*...}
      if [[ $base == "$head" ]]; then comparison=identical
      elif git -C "$TAG_FIXTURE_CHECKOUT" merge-base --is-ancestor "$base" "$head"; then comparison=ahead
      elif git -C "$TAG_FIXTURE_CHECKOUT" merge-base --is-ancestor "$head" "$base"; then comparison=behind
      else comparison=diverged; fi
      respond '200 OK' "$(jq -n --arg status "$comparison" '{status:$status}')"
      exit ;;
    git/ref/tags/*) path="$state/tags/${endpoint##*/}.json" ;;
    *) exit 2 ;;
  esac
  if [[ -f $path ]]; then respond '200 OK' "$(cat "$path")"; else respond '404 Not Found' '{}'; fi
elif [[ $method == POST && $endpoint == git/refs ]]; then
  [[ -n $input ]]
  ref=$(jq -er .ref "$input")
  revision=$(jq -er .sha "$input")
  [[ $ref == refs/tags/* ]]
  tag=${ref#refs/tags/}
  git -C "$TAG_FIXTURE_CHECKOUT" cat-file -e "$revision^{commit}"
  if [[ -f "$state/tags/$tag.json" ]]; then respond '422 Unprocessable Entity' '{}'; exit; fi
  created=$(jq -n --arg revision "$revision" '{object:{type:"commit",sha:$revision}}')
  printf '%s\n' "$created" > "$state/tags/$tag.json"
  if [[ -f "$state/fail-create-response" ]]; then respond '503 Service Unavailable' '{}'; exit; fi
  respond '201 Created' "$created"
elif [[ $method == POST && $endpoint == actions/workflows/release.yml/dispatches ]]; then
  [[ -n $input ]]
  ref=$(jq -er .ref "$input")
  if [[ $ref == main ]]; then
    [[ -f "$state/main" ]]
  else
    [[ -f "$state/tags/$ref.json" ]]
  fi
  respond '204 No Content' '{}'
else
  exit 2
fi
STUB
chmod +x "$scratch/bin/gh"
git -C "$checkout" init -q
git -C "$checkout" config user.name 'Release fixture'
git -C "$checkout" config user.email 'fixture@example.invalid'
git -C "$checkout" config commit.gpgsign false
commit_version() {
  printf '%s\n' "$1" > "$checkout/VERSION"
  git -C "$checkout" add VERSION
  git -C "$checkout" -c core.hooksPath=/dev/null commit -q -m 'Fixture version'
  git -C "$checkout" rev-parse HEAD
}
initial=$(commit_version 0.1.0)
upgrade=$(commit_version 0.2.0)
downgrade=$(commit_version 0.1.5)
initialize() {
  rm -rf -- "$TAG_FIXTURE_STATE"
  mkdir -p "$TAG_FIXTURE_STATE/tags"
  printf '%s\n' "$1" > "$TAG_FIXTURE_STATE/main"
  git -C "$checkout" reset --hard -q
  git -C "$checkout" checkout -q --detach "$1"
}
tag_version() {
  "$root/.github/scripts/tag-version.sh" --root "$checkout" --before "$1" --revision "$2" > "$scratch/result" 2> "$scratch/error"
}
require_success() {
  if ! "$@"; then cat "$scratch/error" >&2; echo "Tag fixture operation failed: $*" >&2; exit 1; fi
}
expect_blocked() {
  if "$@"; then echo "Tag fixture unexpectedly allowed a release at line ${BASH_LINENO[0]}: $*" >&2; exit 1; fi
}
require_tag_owner() {
  jq -e --arg revision "$2" '.object.sha == $revision' "$TAG_FIXTURE_STATE/tags/$1.json" >/dev/null
}

# Only committed VERSION determines the release tag and its immutable owner.
initialize "$upgrade"
printf '9.9.9\n' > "$checkout/VERSION"
require_success tag_version "$initial" "$upgrade"
require_tag_owner 0.2.0 "$upgrade"

# The release command rejects an unmerged source revision.
initialize "$upgrade"
printf '%s\n' "$initial" > "$TAG_FIXTURE_STATE/main"
expect_blocked tag_version "$initial" "$upgrade"

# The release command rejects an automatic version downgrade.
initialize "$downgrade"
expect_blocked tag_version "$upgrade" "$downgrade"

# The command rejects conflicting ownership and retains the existing tag owner.
initialize "$upgrade"
jq -n --arg revision "$initial" '{object:{type:"commit",sha:$revision}}' > "$TAG_FIXTURE_STATE/tags/0.2.0.json"
expect_blocked tag_version "$initial" "$upgrade"
require_tag_owner 0.2.0 "$initial"

# Retrying a lost creation response preserves the committed tag owner.
initialize "$upgrade"
touch "$TAG_FIXTURE_STATE/fail-create-response"
expect_blocked tag_version "$initial" "$upgrade"
require_tag_owner 0.2.0 "$upgrade"
rm "$TAG_FIXTURE_STATE/fail-create-response"
require_success tag_version "$initial" "$upgrade"
require_tag_owner 0.2.0 "$upgrade"
echo 'Tag fixture passed: committed tag ownership, release authorization and lost-response retry decisions'

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
    git/tags/*) path="$state/tag-objects/${endpoint##*/}.json" ;;
    *) exit 2 ;;
  esac
  if [[ -f $path ]]; then respond '200 OK' "$(cat "$path")"; else respond '404 Not Found' '{}'; fi
elif [[ $method == POST && $endpoint == git/refs ]]; then
  [[ -n $input ]]
  ref=$(jq -er .ref "$input")
  revision=$(jq -er .sha "$input")
  [[ $ref == refs/tags/* ]]
  tag=${ref#refs/tags/}
  if [[ -f "$state/fail-create" ]]; then respond '503 Service Unavailable' '{}'; exit; fi
  git -C "$TAG_FIXTURE_CHECKOUT" cat-file -e "$revision^{commit}"
  if [[ -f "$state/tags/$tag.json" ]]; then respond '422 Unprocessable Entity' '{}'; exit; fi
  created=$(jq -n --arg revision "$revision" '{object:{type:"commit",sha:$revision}}')
  printf '%s\n' "$created" > "$state/tags/$tag.json"
  # Model another actor moving the tag before the caller can confirm its owner.
  if [[ -f "$state/move-after-create" ]]; then
    jq -n --arg revision "$(cat "$state/move-after-create")" '{object:{type:"commit",sha:$revision}}' > "$state/tags/$tag.json"
  fi
  if [[ -f "$state/fail-create-response" ]]; then respond '503 Service Unavailable' '{}'; exit; fi
  respond '201 Created' "$created"
elif [[ $method == POST && $endpoint == actions/workflows/release.yml/dispatches ]]; then
  [[ -n $input ]]
  tag=$(jq -er .ref "$input")
  [[ -f "$state/tags/$tag.json" ]]
  if [[ -f "$state/fail-dispatch" ]]; then respond '503 Service Unavailable' '{}'; exit; fi
  # Persist the accepted workflow identity without inventing server-side checks
  # for tag/expected_revision inputs: GitHub accepts those workflow inputs as given.
  cp "$input" "$state/accepted/$tag.json"
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
normalized=$(commit_version $'0.1.0\n')
upgrade=$(commit_version 0.2.0)
downgrade=$(commit_version 0.1.5)
invalid=$(commit_version invalid)
git -C "$checkout" rm -q VERSION
git -C "$checkout" -c core.hooksPath=/dev/null commit -q -m 'Fixture missing version'
missing=$(git -C "$checkout" rev-parse HEAD)
zero=0000000000000000000000000000000000000000
initialize() {
  rm -rf -- "$TAG_FIXTURE_STATE"
  mkdir -p "$TAG_FIXTURE_STATE/tags" "$TAG_FIXTURE_STATE/tag-objects" "$TAG_FIXTURE_STATE/accepted"
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
remote_state() {
  local file
  for file in "$TAG_FIXTURE_STATE/tags/"*.json "$TAG_FIXTURE_STATE/tag-objects/"*.json "$TAG_FIXTURE_STATE/accepted/"*.json; do
    [[ -f $file ]] || continue
    printf '%s\n' "${file#"$TAG_FIXTURE_STATE/"}"
    cat "$file"
  done
}
expect_blocked_without_writes() {
  remote_state > "$scratch/before"
  expect_blocked "$@"
  remote_state > "$scratch/after"
  cmp "$scratch/before" "$scratch/after"
}
require_tag_owner() {
  jq -e --arg revision "$2" '.object.sha == $revision' "$TAG_FIXTURE_STATE/tags/$1.json" >/dev/null
}
require_accepted_release() {
  jq -e --arg version "$1" --arg revision "$2" \
    '.ref == $version and .inputs.tag == $version and .inputs.expected_revision == $revision' \
    "$TAG_FIXTURE_STATE/accepted/$1.json" >/dev/null
}

# Only committed VERSION determines the release, and its exact commit is queued.
initialize "$upgrade"
printf '9.9.9\n' > "$checkout/VERSION"
require_success tag_version "$normalized" "$upgrade"
require_tag_owner 0.2.0 "$upgrade"
require_accepted_release 0.2.0 "$upgrade"

# An unmerged commit cannot create a release; queued main commits remain valid.
initialize "$upgrade"
printf '%s\n' "$initial" > "$TAG_FIXTURE_STATE/main"
expect_blocked_without_writes tag_version "$normalized" "$upgrade"
initialize "$upgrade"
printf '%s\n' "$missing" > "$TAG_FIXTURE_STATE/main"
require_success tag_version "$normalized" "$upgrade"
require_tag_owner 0.2.0 "$upgrade"
require_accepted_release 0.2.0 "$upgrade"

# A normalized value that did not change cannot publish or schedule a release.
initialize "$normalized"
remote_state > "$scratch/unchanged-before"
require_success tag_version "$initial" "$normalized"
remote_state > "$scratch/unchanged-after"
cmp "$scratch/unchanged-before" "$scratch/unchanged-after"

# The first push can release a valid committed version without a before commit.
initialize "$initial"
require_success tag_version "$zero" "$initial"
require_tag_owner 0.1.0 "$initial"
require_accepted_release 0.1.0 "$initial"

# Checkout provenance and valid increasing committed versions authorize writes.
initialize "$initial"
expect_blocked_without_writes tag_version "$initial" "$upgrade"
initialize "$upgrade"
expect_blocked_without_writes tag_version ffffffffffffffffffffffffffffffffffffffff "$upgrade"
initialize "$downgrade"
expect_blocked_without_writes tag_version "$upgrade" "$downgrade"
initialize "$invalid"
expect_blocked_without_writes tag_version "$downgrade" "$invalid"
initialize "$missing"
expect_blocked_without_writes tag_version "$upgrade" "$missing"

# An existing version owned by a different commit cannot be changed or released.
initialize "$upgrade"
jq -n --arg revision "$initial" '{object:{type:"commit",sha:$revision}}' > "$TAG_FIXTURE_STATE/tags/0.2.0.json"
expect_blocked_without_writes tag_version "$normalized" "$upgrade"

# A failed create cannot schedule work; a lost response after creation is safely retried.
initialize "$upgrade"
touch "$TAG_FIXTURE_STATE/fail-create"
expect_blocked_without_writes tag_version "$normalized" "$upgrade"
rm "$TAG_FIXTURE_STATE/fail-create"
touch "$TAG_FIXTURE_STATE/fail-create-response"
tag_version "$normalized" "$upgrade" || true
require_tag_owner 0.2.0 "$upgrade"
if [[ -f "$TAG_FIXTURE_STATE/accepted/0.2.0.json" ]]; then require_accepted_release 0.2.0 "$upgrade"; fi
cp "$TAG_FIXTURE_STATE/tags/0.2.0.json" "$scratch/created-tag"
rm "$TAG_FIXTURE_STATE/fail-create-response"
require_success tag_version "$normalized" "$upgrade"
cmp "$scratch/created-tag" "$TAG_FIXTURE_STATE/tags/0.2.0.json"
require_accepted_release 0.2.0 "$upgrade"

# Dispatch failure preserves the immutable tag and a retry completes scheduling.
initialize "$upgrade"
touch "$TAG_FIXTURE_STATE/fail-dispatch"
expect_blocked tag_version "$normalized" "$upgrade"
require_tag_owner 0.2.0 "$upgrade"
[[ ! -f "$TAG_FIXTURE_STATE/accepted/0.2.0.json" ]]
cp "$TAG_FIXTURE_STATE/tags/0.2.0.json" "$scratch/dispatch-tag"
rm "$TAG_FIXTURE_STATE/fail-dispatch"
require_success tag_version "$normalized" "$upgrade"
cmp "$scratch/dispatch-tag" "$TAG_FIXTURE_STATE/tags/0.2.0.json"
require_accepted_release 0.2.0 "$upgrade"

# Annotated tags retain their object identity while dispatch targets the peeled commit.
initialize "$upgrade"
git -C "$checkout" -c core.hooksPath=/dev/null tag -a 0.2.0 "$upgrade" -m 'Fixture annotated version'
tag_object=$(git -C "$checkout" rev-parse refs/tags/0.2.0)
jq -n --arg tag "$tag_object" '{object:{type:"tag",sha:$tag}}' > "$TAG_FIXTURE_STATE/tags/0.2.0.json"
jq -n --arg revision "$upgrade" '{object:{type:"commit",sha:$revision}}' > "$TAG_FIXTURE_STATE/tag-objects/$tag_object.json"
cp "$TAG_FIXTURE_STATE/tags/0.2.0.json" "$scratch/annotated-tag"
require_success tag_version "$normalized" "$upgrade"
cmp "$scratch/annotated-tag" "$TAG_FIXTURE_STATE/tags/0.2.0.json"
require_accepted_release 0.2.0 "$upgrade"

# Readback must catch an ownership change before any release is scheduled.
initialize "$upgrade"
printf '%s\n' "$initial" > "$TAG_FIXTURE_STATE/move-after-create"
expect_blocked tag_version "$normalized" "$upgrade"
require_tag_owner 0.2.0 "$initial"
[[ ! -f "$TAG_FIXTURE_STATE/accepted/0.2.0.json" ]]
echo 'Tag fixture passed: committed versions, immutable commit ownership, annotated tags and create/dispatch recovery'

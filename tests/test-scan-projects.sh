#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
projects="$tmp/Root Space"
mkdir -p "$projects/nested" "$projects/literal;\$(touch SHOULD_NOT_EXIST)"

make_repo() {
  local path=$1
  git init -q "$path"
  git -C "$path" config user.name "Ryan Macy"
  git -C "$path" config user.email "ryan@macy.dev"
  printf 'test\n' >"$path/file.txt"
  git -C "$path" add file.txt
  git -C "$path" commit -qm init
}

make_repo "$projects/alpha"
make_repo "$projects/nested/beta"
make_repo "$projects/literal;\$(touch SHOULD_NOT_EXIST)"
git -C "$projects/alpha" remote add origin git@github.com:example/alpha.git
git -C "$projects/alpha" worktree add -qb worktree "$projects/worktree"
git -C "$projects/nested/beta" checkout -q --detach HEAD
ln -s "$projects" "$projects/loop"

output=$("$root/bin/scan-projects" 4 20 "$projects" "$projects/alpha" "$tmp/missing")
[[ $(wc -l <<<"$output") -eq 4 ]]
while IFS= read -r line; do
  jq -e 'type == "object" and (.path | startswith("/")) and .marker == ".git" and (.refreshedAt | type == "number") and (.name | type == "string") and (.branch | type == "string") and (.remote | type == "string")' <<<"$line" >/dev/null
done <<<"$output"
[[ $(jq -r 'select(.name == "alpha") | .remote' <<<"$output") == git@github.com:example/alpha.git ]]
[[ -n $(jq -r 'select(.name == "beta") | .branch' <<<"$output") ]]
[[ $output == *'"name":"worktree"'* ]]
[[ ! -e "$tmp/SHOULD_NOT_EXIST" ]]

shallow=$("$root/bin/scan-projects" 1 20 "$projects")
[[ $shallow == *'"name":"alpha"'* ]]
[[ $shallow != *'"name":"beta"'* ]]

capped=$("$root/bin/scan-projects" 8 1 "$projects")
[[ $(wc -l <<<"$capped") -eq 1 ]]

if "$root/bin/scan-projects" 0 10 "$projects" >/dev/null 2>&1; then exit 1; fi
if "$root/bin/scan-projects" 9 10 "$projects" >/dev/null 2>&1; then exit 1; fi
if "$root/bin/scan-projects" 4 0 "$projects" >/dev/null 2>&1; then exit 1; fi
if "$root/bin/scan-projects" 4 501 "$projects" >/dev/null 2>&1; then exit 1; fi
if "$root/bin/scan-projects" 4 10 relative >/dev/null 2>&1; then
  [[ -z $("$root/bin/scan-projects" 4 10 relative) ]]
fi

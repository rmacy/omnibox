#!/usr/bin/env bash
set -euo pipefail

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
home=$root/home
mkdir -p "$home"
writer=${BASH_SOURCE[0]%/*}/../bin/write-usage
target=$home/.local/state/omnibox/usage.json

payload='{"app:test":{"count":2,"row":{"source":"apps","data":"test"}}}'
printf '%s\n' "$payload" | HOME="$home" "$writer" "$target"
[[ $(cat "$target") == "$payload" ]]
[[ $(stat -c %a "$home/.local/state/omnibox") == 700 ]]
[[ $(stat -c %a "$target") == 600 ]]

large=$(printf 'x%.0s' {1..200000})
large_payload=$(printf '{"value":"%s"}' "$large")
printf '%s\n' "$large_payload" | HOME="$home" "$writer" "$target"
[[ $(wc -c <"$target") -eq ${#large_payload} ]]
[[ -z $(find "$home/.local/state/omnibox" -name '.usage.json.tmp.*' -print -quit) ]]

if printf '{}\n' | HOME="$home" "$writer" "$root/wrong.json" >/dev/null 2>&1; then
  echo 'writer accepted unexpected target' >&2
  exit 1
fi

printf 'PASS usage writer: exact stdin, large payload, 0700/0600, atomic cleanup, target guard\n'

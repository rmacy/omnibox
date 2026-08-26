#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shipped" "$tmp/user"

printf '%s\n' '{"protocol":2,"id":"shipped.one"}' >"$tmp/shipped/one.provider.json"
printf '%s\n' '{"protocol":2,"id":"user.one"}' >"$tmp/user/one.provider.json"
printf '%s\n' 'not json' >"$tmp/user/bad.provider.json"
ln -s "$tmp/shipped/one.provider.json" "$tmp/user/link.provider.json"

output=$("$root/bin/scan-providers" "$tmp/shipped" "$tmp/user")
[[ $(wc -l <<<"$output") -eq 2 ]]
jq -e -s 'length == 2 and .[0].manifest.id == "shipped.one" and .[1].manifest.id == "user.one"' <<<"$output" >/dev/null
jq -e -s 'all(.[]; (.sourceDir | startswith("/")) and (.manifestPath | endswith(".provider.json")))' <<<"$output" >/dev/null

[[ -z $("$root/bin/scan-providers" relative "$tmp/missing") ]]
if "$root/bin/scan-providers" "$tmp/shipped" >/dev/null 2>&1; then exit 1; fi

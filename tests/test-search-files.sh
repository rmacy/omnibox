#!/usr/bin/env bash
set -euo pipefail

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/nested"
touch "$root/literal[1].txt" "$root/nested/literal[1]-second.txt" "$root/nested/other.txt"
newline_dir="$root/"$'report\n'
mkdir -p "$newline_dir/home/user"
touch "$newline_dir/home/user/needle.txt" "$root/ spaced.txt "

runner=${BASH_SOURCE[0]%/*}/../bin/search-files
output=$("$runner" 4 1 1 0.2 'literal\[1\]' "$root")
[[ $(printf '%s\n' "$output" | wc -l) -eq 1 ]]
jq -e --arg root "$root/" '.path | startswith($root)' <<<"$output" >/dev/null
[[ $(jq -r '.path' <<<"$output") == *'literal[1]'* ]]

all=$("$runner" 4 10 1 0.2 'literal\[1\]' "$root")
[[ $(printf '%s\n' "$all" | wc -l) -eq 2 ]]
jq -e -s --arg root "$root/" 'all(.[]; (.path | startswith($root)) and (.isDir | type == "boolean"))' <<<"$all" >/dev/null

newline=$("$runner" 4 10 1 0.2 report "$root")
[[ $(printf '%s\n' "$newline" | wc -l) -eq 1 ]]
jq -e --arg path "$newline_dir" '.path == $path' <<<"$newline" >/dev/null
[[ $(jq -r '.isDir' <<<"$newline") == true ]]

spaced=$("$runner" 4 10 1 0.2 spaced "$root")
[[ $(jq -r '.path' <<<"$spaced") == "$root/ spaced.txt " ]]

printf 'PASS file search: JSON framing, newline/whitespace names, root binding, literal pattern, cap\n'

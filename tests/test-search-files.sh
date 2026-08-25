#!/usr/bin/env bash
set -euo pipefail

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/nested"
touch "$root/literal[1].txt" "$root/nested/literal[1]-second.txt" "$root/nested/other.txt"

runner=${BASH_SOURCE[0]%/*}/../bin/search-files
output=$("$runner" 4 1 1 0.2 'literal\[1\]' "$root")
[[ $(printf '%s\n' "$output" | wc -l) -eq 1 ]]
[[ $output == *'literal[1]'* ]]

all=$("$runner" 4 10 1 0.2 'literal\[1\]' "$root")
[[ $(printf '%s\n' "$all" | wc -l) -eq 2 ]]

printf 'PASS file search: literal pattern, depth, result cap, direct argv\n'

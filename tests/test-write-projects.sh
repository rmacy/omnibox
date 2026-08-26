#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
target="$HOME/.local/state/omnibox/projects.json"

payload='{"version":1,"projects":[{"path":"/tmp/a b","name":"a b","branch":"main","remote":""}]}'
printf '%s\n' "$payload" | "$root/bin/write-projects" "$target"
[[ $(<"$target") == "$payload" ]]
[[ $(stat -c %a "${target%/*}") == 700 ]]
[[ $(stat -c %a "$target") == 600 ]]

large=$(printf 'x%.0s' {1..20000})
printf '{"version":1,"projects":[],"padding":"%s"}\n' "$large" | "$root/bin/write-projects" "$target"
[[ $(stat -c %s "$target") -gt 20000 ]]
[[ -z $(compgen -G "${target%/*}/.projects.json.tmp.*" || true) ]]

if printf '{}\n' | "$root/bin/write-projects" "$HOME/other.json" >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$HOME/other.json" ]]

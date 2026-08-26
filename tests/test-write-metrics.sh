#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
target="$HOME/.local/state/omnibox/metrics.json"

valid='{"version":1,"counters":{"opens":1},"sources":{"apps":1},"types":{"app":1},"actions":{"apps/app.open":1},"latency":{"render":{"lt50":1},"async":{},"completion":{}},"workflows":{"runs":0,"successes":0,"failures":0,"cancellations":0,"steps":0}}'
printf '%s\n' "$valid" | "$root/bin/write-metrics" "$target"
[[ $(<"$target") == "$valid" ]]
[[ $(stat -c %a "${target%/*}") == 700 ]]
[[ $(stat -c %a "$target") == 600 ]]

reject() {
  local payload=$1
  if printf '%s\n' "$payload" | "$root/bin/write-metrics" "$target" >/dev/null 2>&1; then
    printf 'accepted forbidden metrics payload: %s\n' "$payload" >&2
    exit 1
  fi
  [[ $(<"$target") == "$valid" ]]
}

reject '{"version":1,"query":"secret","counters":{},"sources":{},"types":{},"actions":{},"latency":{},"workflows":{}}'
reject '{"version":1,"counters":{"opens":"/private/path"},"sources":{},"types":{},"actions":{},"latency":{},"workflows":{}}'
reject '{"version":1,"counters":{},"sources":{},"types":{},"actions":{"providers/file.secret":1},"latency":{},"workflows":{}}'
reject '{"version":1,"counters":{},"sources":{},"types":{},"actions":{"files/native.secret":1},"latency":{},"workflows":{}}'
reject '{"version":1,"counters":{"opens":1000000001},"sources":{},"types":{},"actions":{},"latency":{},"workflows":{}}'
reject 'not json'
if printf '%s\n' "$valid" | "$root/bin/write-metrics" "$HOME/other.json" >/dev/null 2>&1; then exit 1; fi
[[ -z $(compgen -G "${target%/*}/.metrics.json.tmp.*" || true) ]]

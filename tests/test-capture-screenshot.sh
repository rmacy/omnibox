#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
log="$tmp/calls"

cat >"$tmp/bin/omasnap" <<'STUB'
#!/usr/bin/env bash
printf 'omasnap' >"$LOG"
printf '\t%s' "$@" >>"$LOG"
STUB
cat >"$tmp/bin/omarchy" <<'STUB'
#!/usr/bin/env bash
printf 'omarchy' >"$LOG"
printf '\t%s' "$@" >>"$LOG"
STUB
chmod +x "$tmp/bin/omasnap" "$tmp/bin/omarchy"

PATH="$tmp/bin:/usr/bin:/bin" LOG="$log" "$root/bin/capture-screenshot" region --copy
[[ $(<"$log") == $'omasnap\tregion\t--copy' ]]

rm "$tmp/bin/omasnap"
PATH="$tmp/bin:/usr/bin:/bin" LOG="$log" "$root/bin/capture-screenshot" fullscreen --save
[[ $(<"$log") == $'omarchy\tcapture\tscreenshot\tfullscreen\tsave' ]]
PATH="$tmp/bin:/usr/bin:/bin" LOG="$log" "$root/bin/capture-screenshot" smart
[[ $(<"$log") == $'omarchy\tcapture\tscreenshot\tsmart\tslurp' ]]

if PATH="$tmp/bin:/usr/bin:/bin" LOG="$log" "$root/bin/capture-screenshot" invalid --copy >/dev/null 2>&1; then
  exit 1
fi
if PATH="$tmp/bin:/usr/bin:/bin" LOG="$log" "$root/bin/capture-screenshot" region invalid >/dev/null 2>&1; then
  exit 1
fi

printf 'PASS screenshot selector: Omasnap preferred, system capture fallback, validated arguments\n'

#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/omarchy" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "toggle idle --status") printf '%s\n' '{"enabled":false,"class":"disabled","tooltip":"Stay awake"}' ;;
  "toggle nightlight --status") printf '%s\n' '{"enabled":true,"temperature":4200}' ;;
  "bluetooth power is-on") exit 0 ;;
  "toggle enabled bar-off") exit 1 ;;
  "brightness display --no-osd") printf '42%%\n' ;;
  "display text size") printf 'Text size: 14px, GTK factor: 1.1\nTerminal: 11pt\n' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/omarchy"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/omasnap"
chmod +x "$tmp/omasnap"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/tmux"
chmod +x "$tmp/tmux"

actual=$(PATH="$tmp:$PATH" "$root/bin/native-state")
expected=$'idle\tstay awake\nnightlight\ton (4200K)\nbluetooth\ton\nbar\tvisible\nomasnap\tavailable\ntmux\tavailable\nbrightness\t42%\ntext-size\tText size: 14px, GTK factor: 1.1 Terminal: 11pt'
[[ $actual == "$expected" ]]

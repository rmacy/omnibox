#!/usr/bin/env bash
set -euo pipefail

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/bin" "$root/home" "$root/pacman-db"
counter=$root/pacman-calls
printf '0\n' >"$counter"

cat >"$root/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(cat "$PACMAN_COUNTER")
printf '%s\n' "$((count + 1))" >"$PACMAN_COUNTER"
[[ ${1:-} == -Q ]] || exit 2
for i in 0 1 2 3 4 5 6 7 8 9; do printf 'probe-pkg-%s 1.%s\n' "$i" "$i"; done
EOF
chmod +x "$root/bin/pacman"

provider=${BASH_SOURCE[0]%/*}/../providers/packages
env_args=(HOME="$root/home" XDG_CACHE_HOME="$root/cache" PACMAN_COUNTER="$counter" OMNIBOX_PACMAN_DB="$root/pacman-db" PATH="$root/bin:$PATH")
first=$(env "${env_args[@]}" "$provider" probe)
[[ $(printf '%s\n' "$first" | wc -l) -eq 8 ]]
[[ $(cat "$counter") == 1 ]]
cache=$root/cache/omnibox/packages.tsv
[[ $(stat -c %a "$root/cache/omnibox") == 700 ]]
[[ $(stat -c %a "$cache") == 600 ]]

second=$(env "${env_args[@]}" "$provider" probe-pkg-9)
[[ $second == probe-pkg-9$'\t'* ]]
[[ $(cat "$counter") == 1 ]]

touch -d @0 "$cache"
env "${env_args[@]}" "$provider" probe-pkg-0 >/dev/null
[[ $(cat "$counter") == 2 ]]

printf 'PASS packages provider: 8-row cap, cache reuse/invalidation, 0700/0600\n'

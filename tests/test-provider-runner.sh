#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
runner="$root/bin/run-providers"
tmp=$(mktemp -d)
runner_pid=
cleanup() {
  if [[ -n $runner_pid ]] && kill -0 "$runner_pid" 2>/dev/null; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { printf 'FAIL provider runner v2: %s\n' "$*" >&2; exit 1; }

providers="$tmp/providers"
runner_tmp="$tmp/runtime"
mkdir -p "$providers" "$runner_tmp"

cat >"$providers/fast" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
body=$1
context=$2
for n in 1 2 3; do
  jq -cn --arg id "row:$n" --arg title "$body" --arg context "$context" '{
    protocol:2,id:$id,type:"provider",title:$title,subtitle:$context,
    actions:[{id:"open",title:"Open",executor:"argv",argv:["printf","%s",$title],lifecycle:"close",risk:"safe"}]
  }'
done
PROVIDER

cat >"$providers/slow" <<'PROVIDER'
#!/usr/bin/env bash
: >"$SLOW_STARTED"
sleep 2
printf '{"protocol":2,"id":"slow","title":"slow","actions":[]}\n'
PROVIDER

cat >"$providers/unrestricted" <<'PROVIDER'
#!/usr/bin/env bash
jq -cn --arg title "$1" '{
  protocol:2,id:"all",type:"provider",title:$title,
  actions:[{id:"open",title:"Open",executor:"argv",argv:["true"],lifecycle:"close",risk:"safe"}]
}'
PROVIDER

cat >"$providers/hanging" <<'PROVIDER'
#!/usr/bin/env bash
: >"$HANG_STARTED"
trap '' TERM
while :; do sleep 10; done
PROVIDER
chmod 700 "$providers"/fast "$providers"/slow "$providers"/unrestricted "$providers"/hanging

cat >"$providers/fast.provider.json" <<'JSON'
{"protocol":2,"id":"test.fast","executable":"fast","enabled":true,"queryPolicy":"triggered","triggers":["fast"],"context":["workspace"],"timeoutMs":900,"killAfterMs":100,"maxRows":2,"maxLineBytes":16384}
JSON
cat >"$providers/slow.provider.json" <<'JSON'
{"protocol":2,"id":"test.slow","executable":"slow","enabled":true,"queryPolicy":"triggered","triggers":["fast"],"context":[],"timeoutMs":300,"killAfterMs":100,"maxRows":2,"maxLineBytes":16384}
JSON
cat >"$providers/unrestricted.provider.json" <<'JSON'
{"protocol":2,"id":"test.all","executable":"unrestricted","enabled":true,"queryPolicy":"unrestricted","triggers":[],"context":[],"timeoutMs":900,"killAfterMs":100,"maxRows":2,"maxLineBytes":16384}
JSON
cat >"$providers/hanging.provider.json" <<'JSON'
{"protocol":2,"id":"test.hanging","executable":"hanging","enabled":true,"queryPolicy":"triggered","triggers":["hang"],"context":[],"timeoutMs":5000,"killAfterMs":100,"maxRows":1,"maxLineBytes":1024}
JSON

query='fast literal $HOME;*?[x] $(touch SHOULD_NOT_EXIST)'
output="$tmp/output.ndjson"
slow_started="$tmp/slow.started"
start_ns=$(date +%s%N)
TMPDIR="$runner_tmp" SLOW_STARTED="$slow_started" \
  "$runner" "$query" '{"workspace":"3","clipboard":"secret"}' '[]' \
  "$providers/fast.provider.json" "$providers/slow.provider.json" >"$output" &
runner_pid=$!
deadline=$((start_ns + 800000000))
while [[ ! -s $output ]]; do
  (( $(date +%s%N) < deadline )) || fail 'fast provider did not stream within 800ms'
  sleep .01
done
first_ns=$(date +%s%N)
slow_deadline=$(( $(date +%s%N) + 300000000 ))
while [[ ! -e $slow_started ]]; do
  (( $(date +%s%N) < slow_deadline )) || fail 'slow provider did not start concurrently'
  sleep .01
done
artifacts=("$runner_tmp"/run-providers.*/*)
(( ${#artifacts[@]} >= 3 )) || fail 'secure temporary artifacts were not observable'
for artifact in "${artifacts[@]}"; do
  [[ $(stat -c %a "$artifact") == 600 ]] || fail "temporary artifact mode was not 0600: $artifact"
done
wait "$runner_pid"
runner_pid=
end_ns=$(date +%s%N)
first_ms=$(( (first_ns - start_ns) / 1000000 ))
total_ms=$(( (end_ns - start_ns) / 1000000 ))
(( first_ms < 800 )) || fail 'fast publication exceeded bound'
(( total_ms >= 250 && total_ms < 1500 )) || fail "timeout bound was wrong: ${total_ms}ms"
[[ ! -e "$tmp/SHOULD_NOT_EXIST" ]] || fail 'literal query executed shell content'
[[ $(wc -l <"$output") -eq 2 ]] || fail 'provider row cap was not enforced'
jq -e -s 'length == 2 and all(.[]; .providerId == "test.fast")' "$output" >/dev/null \
  || fail 'provider provenance wrapper was invalid'
jq -e -s --arg body "${query#fast }" 'all(.[]; .result.title == $body)' "$output" >/dev/null \
  || fail 'trigger-stripped query body was not literal'
[[ $(<"$output") != *secret* ]] || fail 'unallowlisted context leaked'
jq -e -s 'all(.[]; (.result.subtitle | fromjson) == {workspace:"3"})' "$output" >/dev/null \
  || fail 'allowlisted context was wrong'

[[ -z $("$runner" unrelated '{}' '[]' "$providers/fast.provider.json") ]] \
  || fail 'nonmatching triggered provider executed'
[[ -z $("$runner" anything '{}' '[]' "$providers/unrestricted.provider.json") ]] \
  || fail 'unallowlisted unrestricted provider executed'
allowed=$("$runner" anything '{}' '["test.all"]' "$providers/unrestricted.provider.json")
[[ $(jq -r '.providerId' <<<"$allowed") == test.all ]] \
  || fail 'explicit unrestricted provider did not execute'

ln -s "$providers/fast.provider.json" "$providers/symlink.provider.json"
[[ -z $("$runner" 'fast x' '{}' '[]' "$providers/symlink.provider.json") ]]

hang_started="$tmp/hang.started"
TMPDIR="$runner_tmp" HANG_STARTED="$hang_started" \
  "$runner" 'hang now' '{}' '[]' "$providers/hanging.provider.json" >/dev/null &
runner_pid=$!
deadline=$(( $(date +%s%N) + 800000000 ))
while [[ ! -e $hang_started ]]; do
  (( $(date +%s%N) < deadline )) || fail 'hanging provider did not start'
  sleep .01
done
signal_start=$(date +%s%N)
kill -TERM "$runner_pid"
if wait "$runner_pid"; then fail 'TERM-signaled runner exited successfully'; else status=$?; fi
runner_pid=
signal_ms=$(( ($(date +%s%N) - signal_start) / 1000000 ))
(( status == 143 && signal_ms < 1500 )) || fail 'signal cleanup failed'

shopt -s nullglob
leftovers=("$runner_tmp"/*)
(( ${#leftovers[@]} == 0 )) || fail 'temporary artifacts remained'
if "$runner" only two >/dev/null 2>&1; then fail 'invalid arguments accepted'; fi

printf 'PASS provider runner v2: streaming=%dms total=%dms; trigger, context, allowlist, limits, timeout, cleanup\n' \
  "$first_ms" "$total_ms"

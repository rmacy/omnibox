#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
runner="$script_dir/../bin/run-providers"
case_dir=$(mktemp -d "${TMPDIR:-/tmp}/provider-runner-test.XXXXXXXX")
runner_pid=

cleanup() {
  if [[ -n $runner_pid ]] && kill -0 "$runner_pid" 2>/dev/null; then
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  rm -rf -- "$case_dir"
}
trap cleanup EXIT

fail() {
  printf 'FAIL provider runner: %s\n' "$*" >&2
  exit 1
}

fast_provider="$case_dir/fast provider"
slow_provider="$case_dir/slow provider"
hanging_provider="$case_dir/hanging provider"
slow_done="$case_dir/slow.done"
hang_started="$case_dir/hang.started"
runner_tmp="$case_dir/runner-tmp"
output="$case_dir/output.tsv"
stderr_file="$case_dir/stderr"
mkdir "$runner_tmp"

cat >"$fast_provider" <<'PROVIDER'
#!/usr/bin/env bash
printf '%s\n' "$1"
printf '%s\n' 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
printf '%s\n' 'must-not-appear'
PROVIDER

cat >"$slow_provider" <<'PROVIDER'
#!/usr/bin/env bash
sleep 1
: >"$SLOW_DONE"
printf '%s\n' 'slow-success'
PROVIDER

cat >"$hanging_provider" <<'PROVIDER'
#!/usr/bin/env bash
: >"$HANG_STARTED"
trap '' TERM
while :; do
  sleep 10
done
PROVIDER
chmod 700 "$fast_provider" "$slow_provider" "$hanging_provider"

query='literal $HOME;*?[x] $(false) \ done'
long_line='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
max_line_bytes=40
expected_long=${long_line:0:max_line_bytes}

start_ns=$(date +%s%N)
TMPDIR="$runner_tmp" SLOW_DONE="$slow_done" HANG_STARTED="$hang_started" \
  "$runner" 1.8 .2 2 "$max_line_bytes" "$query" \
  fast "$fast_provider" slow "$slow_provider" hanging "$hanging_provider" \
  >"$output" 2>"$stderr_file" &
runner_pid=$!

fast_deadline_ns=$(( start_ns + 800000000 ))
while [[ ! -s $output ]]; do
  now_ns=$(date +%s%N)
  (( now_ns < fast_deadline_ns )) || fail 'fast output was not observable within 800ms'
  sleep .01
done
fast_ns=$(date +%s%N)
[[ ! -e $slow_done ]] || fail 'slow provider completed before fast output was published'

runner_artifacts=("$runner_tmp"/run-providers.*/*)
(( ${#runner_artifacts[@]} >= 4 )) || fail 'provider capture files were not observable while running'
for artifact in "${runner_artifacts[@]}"; do
  [[ $(stat -c '%a' "$artifact") == 600 ]] || fail \"temporary artifact was not mode 0600: $artifact\"
done

if ! wait "$runner_pid"; then
  runner_pid=
  fail "coordinator exited nonzero: $(<"$stderr_file")"
fi
runner_pid=
end_ns=$(date +%s%N)

fast_ms=$(( (fast_ns - start_ns) / 1000000 ))
total_ms=$(( (end_ns - start_ns) / 1000000 ))
(( fast_ms < 800 )) || fail "fast publication took ${fast_ms}ms"
(( total_ms >= 1500 )) || fail "hanging provider did not remain alive until its hard deadline (${total_ms}ms)"
(( total_ms < 3500 )) || fail "hanging provider exceeded the bounded deadline (${total_ms}ms)"
[[ -e $hang_started ]] || fail 'hanging provider never started'
[[ -e $slow_done ]] || fail 'slow provider did not complete successfully'

expected="$case_dir/expected.tsv"
printf 'fast\t%s\nfast\t%s\nslow\tslow-success\n' "$query" "$expected_long" >"$expected"
if ! cmp -s "$expected" "$output"; then
  diff -u "$expected" "$output" >&2 || true
  fail 'published TSV differed from expected completion order, row cap, or byte cap'
fi

while IFS= read -r line; do
  [[ $line == fast$'\t'* || $line == slow$'\t'* ]] || fail "line lacked the correct provider prefix: $line"
done <"$output"

shopt -s nullglob dotglob
artifacts=("$runner_tmp"/*)
(( ${#artifacts[@]} == 0 )) || fail "temporary artifacts remained: ${artifacts[*]}"

rm -f "$hang_started"
signal_output="$case_dir/signal-output.tsv"
TMPDIR="$runner_tmp" HANG_STARTED="$hang_started" \
  "$runner" 10 .2 1 "$max_line_bytes" signal hanging "$hanging_provider" \
  >"$signal_output" 2>>"$stderr_file" &
runner_pid=$!

signal_start_deadline_ns=$(( $(date +%s%N) + 800000000 ))
while [[ ! -e $hang_started ]]; do
  (( $(date +%s%N) < signal_start_deadline_ns )) || fail 'signal-cleanup provider did not start'
  sleep .01
done
signal_start_ns=$(date +%s%N)
kill -TERM "$runner_pid"
if wait "$runner_pid"; then
  runner_pid=
  fail 'TERM-signaled coordinator exited successfully'
else
  signal_status=$?
fi
runner_pid=
signal_end_ns=$(date +%s%N)
signal_ms=$(( (signal_end_ns - signal_start_ns) / 1000000 ))
(( signal_status == 143 )) || fail "TERM-signaled coordinator exited with status $signal_status"
(( signal_ms < 1500 )) || fail "signal cleanup took ${signal_ms}ms"

artifacts=("$runner_tmp"/*)
(( ${#artifacts[@]} == 0 )) || fail "temporary artifacts remained after signal: ${artifacts[*]}"

if "$runner" 0 .1 1 1 query >/dev/null 2>&1; then
  fail 'zero timeout was accepted'
fi
if "$runner" 1 .1 1 1 query unpaired >/dev/null 2>&1; then
  fail 'unpaired provider arguments were accepted'
fi

printf 'PASS provider runner: fast=%dms, total=%dms, signal-cleanup=%dms; streaming, prefixes, limits, timeout, literal argv, cleanup ok\n' \
  "$fast_ms" "$total_ms" "$signal_ms"

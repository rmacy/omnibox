#!/usr/bin/env bash
set -euo pipefail

if ! command -v omarchy-shell >/dev/null 2>&1 ||
   [[ $(omarchy-shell shell call bitr0t.omnibox ping '{}' 2>/dev/null || true) != ok ]]; then
  printf 'SKIP QML smoke: running bitr0t.omnibox shell plugin unavailable\n'
  exit 0
fi

cleanup() { omarchy-shell shell hide bitr0t.omnibox >/dev/null 2>&1 || true; }
trap cleanup EXIT

[[ $(omarchy-shell shell summon bitr0t.omnibox '{"query":"=7*6"}') == ok ]]
[[ $(omarchy-shell shell call bitr0t.omnibox currentQuery '') == '=7*6' ]]
[[ $(omarchy-shell shell call bitr0t.omnibox hintFor 0) == 'Enter copies' ]]

omarchy-shell shell summon bitr0t.omnibox '{"query":"ghost"}' >/dev/null
sleep 1
natural=$(omarchy-shell shell call bitr0t.omnibox naturalRowsHeight 0)
viewport=$(omarchy-shell shell call bitr0t.omnibox rowsHeight 0)
(( natural >= viewport ))
(( viewport <= 420 ))

omarchy-shell shell summon bitr0t.omnibox '{"query":"bauhaus"}' >/dev/null
sleep 1
omarchy-shell shell summon bitr0t.omnibox '{"query":"smoke-no-match-zzzxqv"}' >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox hintFor 0) != 'Open · Alt+Enter reveals' ]]

omarchy-shell shell summon bitr0t.omnibox '{"query":"smoke-a"}' >/dev/null
omarchy-shell shell summon bitr0t.omnibox '{"query":"smoke-b"}' >/dev/null
omarchy-shell shell summon bitr0t.omnibox '{"query":"smoke-c"}' >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox currentQuery '') == smoke-c ]]

printf 'PASS QML smoke: IPC, calculator, capped scroll, stale-row rejection, latest query\n'

#!/usr/bin/env bash
set -euo pipefail

if ! command -v omarchy-shell >/dev/null 2>&1 ||
   [[ $(omarchy-shell shell call bitr0t.omnibox ping '{}' 2>/dev/null || true) != ok ]]; then
  printf 'SKIP QML smoke: running bitr0t.omnibox shell plugin unavailable\n'
  exit 0
fi

cleanup() { omarchy-shell shell hide bitr0t.omnibox >/dev/null 2>&1 || true; }
trap cleanup EXIT

matrix=$(omarchy-shell shell call bitr0t.omnibox stageAActionMatrix '')
[[ $matrix == *'"apps":["app.open","app.launch-new"'* ]]
[[ $matrix == *'"windows":["window.focus","window.move-workspace","window.move-monitor","window.float","window.fullscreen","window.close"]'* ]]
[[ $matrix == *'"files":["file.open","file.reveal","file.edit","file.terminal","file.copy-path"'* ]]
[[ $matrix == *'"calc":["calculation.copy","calculation.paste"]'* ]]
[[ $matrix == *'"web":["web.open","web.copy-url"]'* ]]
[[ $matrix == *'"clipboard":["clipboard.paste","clipboard.copy-again"]'* ]]
[[ $matrix == *'"ssh":["ssh.connect","ssh.copy-host"'* ]]
[[ $matrix == *'"providers":["provider.run"]'* ]]

native_status=
for _ in {1..20}; do
  native_status=$(omarchy-shell shell call bitr0t.omnibox nativeCatalogStatus '')
  [[ $native_status == *'"loaded":true'* ]] && break
  sleep 0.1
done
(( $(omarchy-shell shell call bitr0t.omnibox nativeCommandCount '') > 100 ))
[[ $native_status == *'"themes":'* ]]
[[ $native_status == *'"idle":'* ]]
[[ $native_status == *'"omasnap":'* ]]

reminder_preview=$(omarchy-shell shell call bitr0t.omnibox nativePreview 'remind 20 Check oven')
[[ $reminder_preview == *'Remind in 20 minutes: Check oven'* ]]
[[ $reminder_preview == *'"actions":["native.run","native.inspect"]'* ]]
theme_preview=$(omarchy-shell shell call bitr0t.omnibox nativePreview 'theme bauhaus')
[[ $theme_preview == *'Apply theme Bauhaus Instrument'* ]]
[[ $theme_preview == *'"confirm":true'* ]]
version_preview=$(omarchy-shell shell call bitr0t.omnibox nativePreview 'installed omarchy version')
[[ $version_preview == *'Print the installed Omarchy version'* ]]
[[ $version_preview == *'learning.pin'* ]]
update_preview=$(omarchy-shell shell call bitr0t.omnibox nativePreview 'Update Omarchy and system packages')
[[ $update_preview == *'"risk":"privileged","lifecycle":"terminal"'* ]]
screenshot_preview=$(omarchy-shell shell call bitr0t.omnibox nativePreview screenshot)
[[ $screenshot_preview == *'native.run-template'* ]]
[[ $(omarchy-shell shell call bitr0t.omnibox enterNativeArgumentPreview screenshot) == Arguments ]]
omarchy-shell shell call bitr0t.omnibox activateAt 0 >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Arguments ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null

[[ $(omarchy-shell shell call bitr0t.omnibox enterNativeArgumentPreview 'Set the default audio output and move active streams') == Arguments ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null

omarchy-shell shell summon bitr0t.omnibox '{"query":"show reminders"}' >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox objectIdAt 0) == native:* ]]
omarchy-shell shell call bitr0t.omnibox activateAt 0 >/dev/null
sleep 0.2
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Result ]]
reminder_status=$(omarchy-shell shell call bitr0t.omnibox actionStatus '')
[[ $reminder_status == *'"success":true'* ]]
[[ $reminder_status != *'"detail":""'* ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null

[[ $(omarchy-shell shell summon bitr0t.omnibox '{"query":"=7*6"}') == ok ]]
[[ $(omarchy-shell shell call bitr0t.omnibox currentQuery '') == '=7*6' ]]
[[ $(omarchy-shell shell call bitr0t.omnibox hintFor 0) == 'Copy result · Tab actions' ]]

[[ $(omarchy-shell shell call bitr0t.omnibox objectIdAt 0) == calc ]]
omarchy-shell shell call bitr0t.omnibox enterActions 0 >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Actions ]]
[[ $(omarchy-shell shell call bitr0t.omnibox objectIdAt 0) == calculation.copy ]]
[[ $(omarchy-shell shell call bitr0t.omnibox interactionBreadcrumb '') == '= 42' ]]
[[ $(omarchy-shell shell call bitr0t.omnibox hintFor 0) == Enter ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Search ]]
[[ $(omarchy-shell shell call bitr0t.omnibox currentQuery '') == '=7*6' ]]

omarchy-shell shell summon bitr0t.omnibox '{"query":"shutdown"}' >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox objectIdAt 0) == sys:shutdown ]]
omarchy-shell shell call bitr0t.omnibox enterActions 0 >/dev/null
omarchy-shell shell call bitr0t.omnibox activateAt 0 >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Confirm ]]
[[ $(omarchy-shell shell call bitr0t.omnibox hintFor 0) == 'Enter confirms · Escape cancels' ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Actions ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null

omarchy-shell shell summon bitr0t.omnibox '{"query":"ghost"}' >/dev/null
omarchy-shell shell call bitr0t.omnibox enterActions 0 >/dev/null
omarchy-shell shell call bitr0t.omnibox activateAt 3 >/dev/null
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Arguments ]]
[[ $(omarchy-shell shell call bitr0t.omnibox setInteractionQuery smoke-alias) == smoke-alias ]]
[[ $(omarchy-shell shell call bitr0t.omnibox objectIdAt 0) == argument:* ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null

[[ $(omarchy-shell shell call bitr0t.omnibox runHealthCheck '') == Running ]]
sleep 0.2
[[ $(omarchy-shell shell call bitr0t.omnibox currentMode '') == Result ]]
[[ $(omarchy-shell shell call bitr0t.omnibox hintFor 0) == 'Escape returns' ]]
omarchy-shell shell call bitr0t.omnibox returnInteraction '' >/dev/null

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

printf 'PASS QML smoke: IPC, actions, arguments, confirm, back, capped scroll, stale rows\n'

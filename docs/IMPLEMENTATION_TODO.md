# Omnibox 2.0 Implementation TODO

**Product requirements:** [PRODUCT_REQUIREMENTS.md](./PRODUCT_REQUIREMENTS.md)  
**Status:** Proposed; no item below is implemented merely because it is listed.

This checklist is dependency ordered. A stage gate must pass before work begins
on the next stage. Check an item only when its observable acceptance statement
is true.

## Definition of done

Omnibox 2.0 is complete only when all of the following are true:

- Every existing result source uses the typed `Result`/`Action` contract.
- Search, Actions, Arguments, Confirm, Running, and Result modes work through
  one bounded navigation controller.
- Input-derived operations use argv-safe execution; obsolete `kind`/`payload`
  and opaque provider-action paths are removed.
- The cached Omarchy command catalog, typed native adapters, global ranking,
  safe learning, Project Resume, workflows, and provider v2 satisfy their stage
  gates.
- Destructive, privileged, failed, canceled, and stale operations have tested
  behavior.
- No forbidden content is persisted in usage or aggregate metrics.
- Unit, helper, integration, live QML, plugin validation, coverage, docs, and
  rollback checks pass from a clean checkout.

## Stage A — Action kernel

### A0 — Baseline and contracts

- [ ] **Record current behavioral fixtures for all ten result sources.** Add
  fixtures or focused tests covering apps, windows, files, calculations, web,
  shell, system, clipboard, SSH, and providers; acceptance: each current primary
  activation can fail a test if lost during migration.
- [ ] **Record a live keyboard baseline.** Exercise Escape, Up/Down,
  PageUp/PageDown, Enter, and file `Alt+Enter`; acceptance: observed behavior
  matches [`Omnibox.qml` lines 1549–1590](../Omnibox.qml#L1549-L1590) and the
  existing QML smoke remains green.
- [ ] **Record ranking fixtures that expose fixed bucket behavior.** Include an
  exact system/file/window match competing with a weak app match; acceptance:
  fixtures document current order from [`Omnibox.qml` lines 873–924](../Omnibox.qml#L873-L924)
  and will fail once global rank expectations are applied.
- [ ] **Define `Result`, `Action`, typed argument, risk, and lifecycle schemas in
  a pure ES5-compatible JS module.** Acceptance: schema validators reject
  missing stable IDs, empty action lists, invalid executor kinds, oversized argv,
  and contradictory `close`/`keepOpen` policies.
- [ ] **Define stable built-in type and action IDs.** Acceptance: every current
  source has documented IDs and no ID contains raw clipboard content, raw query
  text, arbitrary command text, or a mutable positional index.
- [ ] **Define mode-transition invariants.** Acceptance: a transition table
  covers Search, Actions, Arguments, Confirm, Running, and Result, including
  Escape/back, cancellation, close, and stale async completion.

### A1 — Pure logic modules

- [ ] **Extract query parsing into `js/Query.js`.** Acceptance: `>command`,
  forced calculation, normal search, aliases, and future typed intent tokens are
  parsed without QML object dependencies; existing behavior is unchanged.
- [ ] **Implement a command/source registry in pure JS.** Acceptance: sources
  register ID, label, match function, result normalizer, and availability;
  `rebuildDisplay()` no longer requires a hard-coded bucket object for each new
  source.
- [ ] **Implement global score composition in `js/Ranking.js`.** Acceptance:
  exact/prefix/fuzzy, intent, pin, frequency, recency, and source tie-breakers
  are individually unit tested and produce deterministic total ordering.
- [ ] **Add score-explanation output for tests and local diagnostics.**
  Acceptance: a result can report component scores without recording the query.
- [ ] **Implement action validation and resolution in `js/Actions.js`.**
  Acceptance: dynamic values resolve only to complete argv elements or typed
  built-ins; no resolver returns an interpolated shell fragment.
- [ ] **Implement bounded navigation in `js/Flow.js`.** Acceptance: stack depth
  never exceeds four, Escape pops exactly one level, and returning restores a
  stable selection when present.
- [ ] **Bring each new JS module above the repository’s 90% statements,
  branches, functions, and lines thresholds.** Acceptance: `npm run coverage`
  enforces the threshold rather than excluding new modules.

### A2 — QML action surface

- [ ] **Add root mode and flow state to `Omnibox.qml`.** Acceptance: opening
  starts in Search; closing clears the flow and cancels active work.
- [ ] **Render an eliding breadcrumb above or within the existing compact input
  surface.** Acceptance: `file › Send to device › desktop` remains readable on
  the current card and does not force a permanent second pane.
- [ ] **Prototype both `Tab` and `Ctrl+K` action entry.** Acceptance: live QML
  testing establishes one canonical documented key with no conflict in the
  text field; the decision is recorded in the PRD open-decision section.
- [ ] **Render the selected result’s ordered action list.** Acceptance: Enter
  continues to run the primary action directly; the canonical action key opens
  secondary actions without changing the selected object.
- [ ] **Render typed argument pickers through the same ListView.** Acceptance:
  enum, integer, string, file, project, workspace, monitor, theme, and device
  arguments validate before advancing.
- [ ] **Implement Confirm mode.** Acceptance: it identifies action and target,
  requires a second explicit Enter, and Escape returns without execution.
- [ ] **Implement Running and Result modes.** Acceptance: bounded progress,
  success, exit status, and redacted stderr are visible for `keepOpen` actions.
- [ ] **Preserve pointer gating across modes.** Acceptance: opening or async
  reordering cannot activate a row solely because the pointer was already over
  its location.
- [ ] **Preserve stable selection across asynchronous rebuilds.** Acceptance:
  selected `Result.id` survives provider/file/window batches when still present.
- [ ] **Make visual states accessible.** Acceptance: selected, running,
  successful, warning, and destructive states are distinguishable without color
  alone in one light and one dark Omarchy theme.

### A3 — Safe executor

- [ ] **Add an argv executor backed by the real `Util.execArgv(argv)` API.**
  Acceptance: paths/messages containing spaces, quotes, `$()`, semicolons, and
  leading dashes remain literal; source contract is
  `/usr/share/omarchy/shell/Commons/Util.qml:57-63`.
- [ ] **Add typed built-ins for app launch, window dispatch, copy text, clipboard
  paste, and flow continuation.** Acceptance: built-ins accept validated fields,
  not arbitrary command strings.
- [ ] **Add a captured-process executor for `keepOpen` actions.** Acceptance:
  latest request wins; timeout/cancel terminates the active process; stale
  stdout/stderr cannot update a newer flow.
- [ ] **Add a terminal execution policy.** Acceptance: privileged interactive
  work opens in a visible terminal and never creates an invisible sudo prompt.
- [ ] **Add a destructive-risk policy.** Acceptance: close window, logout,
  reboot, shutdown, package removal, destructive workflow, and equivalent
  provider actions cannot bypass Confirm.
- [ ] **Bound executor inputs and outputs.** Acceptance: maximum argv count,
  element bytes, runtime, stdout, and stderr are enforced and adversarially
  tested.
- [ ] **Retain explicit `>command` expert mode as a separate shell boundary.**
  Acceptance: raw commands are visibly labeled, never learned or pinned with
  content, and do not pass through typed action substitution.

### A4 — Migrate current sources

- [ ] **Migrate applications.** Actions: Open/focus, launch new when supported,
  Pin/Unpin; acceptance: AppLibrary icons and primary launch remain correct.
- [ ] **Migrate windows.** Actions: Focus plus only live-verified workspace,
  monitor, floating/fullscreen, and close operations; acceptance: focus still
  uses the Omarchy Hyprland Lua dispatcher documented at
  [`Omnibox.qml` lines 1064–1068](../Omnibox.qml#L1064-L1068).
- [ ] **Migrate files.** Actions: Open, Reveal, Open in editor, Terminal here,
  Copy path, conditional Taildrop; acceptance: current Enter and `Alt+Enter`
  behavior remains available through typed actions.
- [ ] **Migrate calculations.** Actions: Copy and Paste; acceptance: current
  calculator behavior and test vectors are unchanged.
- [ ] **Migrate web URLs and searches.** Make one default result with engines as
  actions; acceptance: configured engines remain hot-reloadable and duplicate
  rows no longer crowd the list.
- [ ] **Migrate shell expert mode.** Acceptance: terminal/background choices are
  actions and raw command content remains excluded from state.
- [ ] **Migrate current system rows.** Acceptance: lock, clipboard, emoji, theme,
  menu, keybindings, screenshot, suspend, logout, reboot, and shutdown retain
  primary behavior, with confirmations added where policy requires.
- [ ] **Migrate clipboard text and images.** Acceptance: paste/copy/open behavior
  uses argv-safe helpers and clipboard content never becomes a stable ID or
  metric.
- [ ] **Migrate SSH hosts.** Actions: Connect and Copy host; acceptance: host
  validation remains at least as strict as [`Omnibox.qml` lines 179–180](../Omnibox.qml#L179-L180).
- [ ] **Temporarily migrate current providers into an internal typed adapter.**
  Acceptance: Stage A preserves provider primary activation without expanding
  the public TSV contract; this adapter is deleted in Stage D.
- [ ] **Remove the old `makeRow(... kind, data ...)` API.** Acceptance: no caller
  creates the single-operation schema from [`Omnibox.qml` lines 385–397](../Omnibox.qml#L385-L397).
- [ ] **Remove `kind`/`payload` display roles and dispatcher branches.**
  Acceptance: [`Omnibox.qml` lines 943–953 and 1038–1089](../Omnibox.qml#L943-L1089)
  are replaced by Result/Action dispatch; no compatibility alias remains.

### A5 — Ranking and safe learning

- [ ] **Replace fixed source concatenation with one globally sorted candidate
  list.** Acceptance: exact matches can cross source boundaries and deterministic
  fixtures pass.
- [ ] **Add source badges without requiring contiguous sections.** Acceptance:
  mixed global results retain provenance and compact row height.
- [ ] **Add Pin, Unpin, Set alias, Forget, and Reset learning actions.**
  Acceptance: every mutation is visible and takes effect immediately.
- [ ] **Version and migrate usage state atomically.** Acceptance: valid current
  app/file/system/SSH history migrates; invalid or sensitive categories are
  dropped; directory/file modes remain `0700`/`0600`.
- [ ] **Learn stable action IDs with count and recency decay.** Acceptance: no
  argv, raw query, path outside already-approved stable file identity, clipboard
  content, calculation, or provider output is added.
- [ ] **Build the empty state from Pinned, recent safe actions, and deterministic
  suggestions.** Acceptance: missing targets fail closed and age out.
- [ ] **Add state inspection and reset UI/actions.** Acceptance: the user can see
  every retained stable ID/alias and remove it without editing JSON.

### Stage A gate

- [ ] **Pass the Action Kernel gate.** Observable result: every current source
  runs through typed Result/Action models; secondary file/window/app/clipboard/
  SSH actions work live; global ranking and safe learning work; confirmation,
  error, cancel, and stale-result cases pass; the obsolete dispatcher is gone.

## Stage B — Native Omarchy control

### B0 — Catalog and policy

- [ ] **Implement a one-shot cached loader for `omarchy commands --json`.**
  Acceptance: it runs once per shell lifetime or explicit refresh, validates the
  documented fields from `/usr/share/omarchy/bin/omarchy:669-684`, and does not
  block cached initial results.
- [ ] **Handle catalog absence, invalid JSON, and schema drift.** Acceptance:
  Omnibox keeps all non-catalog sources usable and reports one bounded error.
- [ ] **Index route, summary, aliases, args, and examples.** Acceptance: searches
  such as `network`, `capture`, and `theme` find relevant commands by summary
  without knowing the route.
- [ ] **Exclude hidden commands by default.** Acceptance: a fixture containing a
  hidden exact match does not surface without explicit developer configuration.
- [ ] **Create a conservative command policy registry.** Acceptance: every
  directly executable catalog entry is classified by argument resolution,
  interaction, terminal need, privilege, destructiveness, and lifecycle.
- [ ] **Do not treat `requires_sudo` as a safety verdict.** Acceptance: tests show
  non-sudo destructive commands still require confirmation and harmless
  sudo-required commands still use a visible terminal.
- [ ] **Add a diagnostic action that shows catalog provenance and declared
  usage.** Acceptance: it never executes the command.

### B1 — Typed native adapters

- [ ] **Implement reminder parsing and execution.** Acceptance:
  `remind 20 check oven` resolves to argv
  `['omarchy','reminder','20','Check oven']`; zero, negative, or non-integer
  minutes do not produce an executable result.
- [ ] **Implement reminder listing.** Acceptance: `omarchy reminder show --json`
  results are bounded and active reminder content is not persisted in usage or
  metrics.
- [ ] **Implement inline theme selection.** Acceptance: candidates come from
  `omarchy theme list`; selection executes `omarchy theme set <full-name>` as
  argv and works for names with spaces.
- [ ] **Implement capture mode and destination pickers.** Acceptance:
  screenshot smart/region/windows/fullscreen and copy/save options execute the
  catalog-declared argv; unsupported combinations are absent.
- [ ] **Implement idle, nightlight, notification-silencing, Bluetooth, and bar
  toggles where live state is available.** Acceptance: rows report only observed
  state and refresh after execution.
- [ ] **Implement audio adjustment adapter.** Acceptance: validated raise/lower/
  mute or signed step values pass as one argv element and retain Omarchy OSD.
- [ ] **Implement brightness adjustment adapter.** Acceptance: validated signed
  percentage/off/on values pass as one argv element and target the focused
  display unless the user explicitly chooses another.
- [ ] **Implement theme/background and text-size adapters only after their live
  command ranges are verified.** Acceptance: values come from command output or
  declared range; no free-form shell template exists.
- [ ] **Add direct pins/aliases for safe native actions.** Acceptance: state stores
  command/action IDs and validated enum values only; reminder messages and
  arbitrary arguments are excluded.

### B2 — Long-tail command discovery

- [ ] **Surface safe no-argument commands through the generic catalog.**
  Acceptance: primary action is enabled only after policy classification.
- [ ] **Route commands with unresolved arguments into Arguments mode.**
  Acceptance: no required-argument command is executed merely to display help.
- [ ] **Route terminal/interactive commands through terminal policy.**
  Acceptance: gum/TUI/password prompts are visible and Omnibox does not remain
  falsely in Running.
- [ ] **Confirm destructive or remote generic actions.** Acceptance: command,
  target arguments, and provenance are shown before execution.
- [ ] **Add catalog ranking fixtures.** Acceptance: human-summary matches compete
  globally without burying exact files/apps and catalog result caps prevent
  flooding.

### Stage B gate

- [ ] **Pass the Native Omarchy gate.** Observable result: the documented
  reminder, theme, capture, toggle, audio, and brightness flows complete without
  raw shell entry; long-tail discovery is cached and policy-gated; privileged
  and destructive live scenarios behave correctly.

## Stage C — Projects and workflows

### C0 — Project discovery

- [ ] **Extend JSONC configuration with validated project roots and maximum
  depth.** Acceptance: roots hot-reload, `~` expands safely, nonexistent roots
  are ignored, and `$HOME` is not crawled by default.
- [ ] **Implement a bounded project scanner helper.** Acceptance: it receives
  roots/depth as argv, discovers `.git` projects without following unsafe loops,
  bounds rows/runtime/output, and never runs on the UI thread.
- [ ] **Cache only stable project metadata atomically at mode `0600`.**
  Acceptance: cache contains path, display name, marker, optional branch, and
  refresh timestamp—no file contents or Git credentials/remotes with secrets.
- [ ] **Refresh project data through explicit refresh and bounded filesystem
  observation.** Acceptance: created/moved/deleted projects appear without a
  shell restart and scans coalesce during bursts.
- [ ] **Add project ranking and availability tests.** Acceptance: explicit alias,
  exact name, path component, pin, frequency, and recency order deterministically.

### C1 — Project actions

- [ ] **Implement Open in editor with the real `omarchy launch editor <path>`
  seam.** Acceptance: paths with spaces and leading dashes remain argv literals.
- [ ] **Implement Open terminal here after verifying the active terminal’s
  supported working-directory contract.** Acceptance: no `bash -lc 'cd ...'`
  string is built from the path.
- [ ] **Implement file search scoped to the selected project.** Acceptance:
  selecting a project enters a breadcrumb-scoped search and reuses bounded
  latest-request-wins file search.
- [ ] **Implement Git remote browsing only for recognized HTTPS/SSH remotes.**
  Acceptance: credentials/userinfo are rejected or redacted and the resolved URL
  is shown before opening.
- [ ] **Implement optional tmux attach/create after capability detection.**
  Acceptance: a stable session name is derived deterministically and repeated
  activation attaches rather than duplicates.
- [ ] **Implement Project Resume as idempotent focus-before-launch steps.**
  Acceptance: repeated execution does not duplicate identified editor windows
  or tmux sessions; optional missing steps do not fail required steps.

### C2 — Workflow engine

- [ ] **Add a validated `workflows` JSONC schema.** Acceptance: stable IDs,
  aliases, typed parameters, registered action references, optional steps,
  stop-on-failure, and risk are accepted; arbitrary executable strings are not.
- [ ] **Resolve workflow arguments through typed pickers.** Acceptance: file,
  project, theme, device, workspace, monitor, enum, integer, and bounded string
  arguments have specific validation.
- [ ] **Render a concrete workflow plan.** Acceptance: step order, targets,
  optional steps, remote/destructive markers, and redacted values are visible.
- [ ] **Execute one step at a time.** Acceptance: next step starts only after the
  current required step succeeds; no silent retry or parallel side effects.
- [ ] **Implement cancellation and stale completion protection.** Acceptance:
  cancel stops the active process, prevents future steps, and late output cannot
  change a new flow.
- [ ] **Stop on the first required failure and show partial progress.**
  Acceptance: completed/pending/failed steps are visible and the UI makes no
  rollback claim.
- [ ] **Learn only workflow IDs.** Acceptance: usage and metrics contain no
  parameter values, plans, paths beyond approved stable project identity, or
  stdout/stderr.
- [ ] **Add adversarial workflow tests.** Acceptance: cycles, excessive depth,
  unknown actions, oversized args, injection strings, cancellation races, and
  partial failure are rejected or handled deterministically.

### Stage C gate

- [ ] **Pass the Projects and Workflows gate.** Observable result: an opt-in
  project can be found, acted on, and resumed; Project Resume replaces at least
  four documented manual steps; three repeated runs create no duplicate
  identified windows/sessions; workflow plan/failure/cancel behavior is visible.

## Stage D — Extension platform

### D0 — Provider trust model

- [ ] **Document that providers are unsandboxed executable code.** Acceptance:
  README and provider docs state that current timeout/output bounds do not
  restrict filesystem or network access.
- [ ] **Define a versioned provider manifest.** Acceptance: protocol, stable ID,
  executable path, triggers/prefix, capabilities, query policy, context fields,
  timeout, and limits validate before execution.
- [ ] **Require explicit enablement for unrestricted-query providers.**
  Acceptance: a provider cannot receive every query merely by being executable
  in a directory.
- [ ] **Expose provider provenance on every result and confirmation.**
  Acceptance: the user can identify which executable supplied an action.
- [ ] **Define allowed context fields.** Acceptance: clipboard/file contents and
  raw prior arguments are absent by default; requested metadata is minimized to
  the manifest allowlist.

### D1 — NDJSON protocol and runner

- [ ] **Specify the provider v2 NDJSON schema with byte/field/action limits.**
  Acceptance: required Result/Action fields, executor kinds, argv bounds, and
  unknown-field behavior are documented and fixture-tested.
- [ ] **Update `bin/run-providers` to select providers by trigger policy.**
  Acceptance: nonmatching providers do not execute; matching providers remain
  concurrent, timed out, kill-bounded, row-bounded, and byte-bounded.
- [ ] **Parse each provider line independently.** Acceptance: malformed JSON
  rejects one row without discarding valid rows from that provider or mutating
  another provider’s state.
- [ ] **Validate typed provider actions before display.** Acceptance: invalid
  IDs, executor kinds, argv, next types, risk, or lifecycle fields reject the
  action/result with a bounded diagnostic.
- [ ] **Prevent providers from overriding first-party IDs or actions.**
  Acceptance: provider namespace is mandatory and collision fixtures fail
  closed.
- [ ] **Preserve latest-request-wins streaming.** Acceptance: completed provider
  batches appear incrementally; stale query batches never publish.
- [ ] **Add provider action confirmation and provenance.** Acceptance: shell,
  remote, destructive, and privileged claims follow core policy rather than
  provider preference alone.

### D2 — Clean cutover

- [ ] **Migrate the shipped packages provider to v2.** Acceptance: package search
  retains cache invalidation, mode `0600`, bounds, ranking, and test coverage.
- [ ] **Migrate provider documentation and examples to manifests plus NDJSON.**
  Acceptance: every copied example validates and runs in the live plugin.
- [ ] **Provide an explicit user migration note for custom TSV providers.**
  Acceptance: old/new field mapping and rollback to the prior plugin release are
  documented without claiming automatic conversion.
- [ ] **Remove the temporary Stage A typed adapter and TSV parser.** Acceptance:
  no code path accepts `label<TAB>detail<TAB>action`; no dual protocol remains.
- [ ] **Remove obsolete tests and fixtures only after v2 replacements defend the
  same behavior.** Acceptance: coverage does not fall and validator accepts the
  final tree.

### Stage D gate

- [ ] **Pass the Extension Platform gate.** Observable result: manifests gate
  provider invocation; v2 typed actions stream safely with provenance; malicious
  fixtures remain bounded; shipped provider and docs use v2; TSV execution is
  absent.

## Cross-cutting metrics, security, and quality

### Local aggregate metrics

- [ ] **Define an allowlisted metrics schema.** Acceptance: only aggregate opens,
  transitions, stable first-party source/type/action IDs, selection movement,
  success/failure, workflow step counts, and latency buckets are accepted.
- [ ] **Reject forbidden values at the writer boundary.** Acceptance: raw query,
  hash of query, clipboard, path, provider label/output, shell command, SSH host,
  workflow args, and stdout/stderr fixtures cannot be serialized.
- [ ] **Write metrics atomically at mode `0600`.** Acceptance: concurrent updates,
  invalid prior state, size cap, reset, and disabled configuration are tested.
- [ ] **Add an inspect/reset action.** Acceptance: user can view aggregate keys
  and clear the file without a terminal.
- [ ] **Capture the pre-feature local baseline before evaluating product
  thresholds.** Acceptance: rank-one use, selection correction, cancellation,
  and completion-latency buckets contain no content.

### Security review

- [ ] **Threat-model every executor and provider boundary.** Acceptance: trust,
  input, output, persistence, privilege, confirmation, and cancellation are
  recorded for argv, built-in, workflow, expert shell, and provider actions.
- [ ] **Test shell metacharacters as literal data.** Acceptance: `$()`, backticks,
  quotes, semicolons, newlines, leading dashes, Unicode, and long strings cannot
  become commands through typed paths.
- [ ] **Test destructive-action policy bypasses.** Acceptance: primary action,
  alias, pin, empty state, provider result, workflow step, keyboard shortcut, and
  mouse activation all enter Confirm.
- [ ] **Test visible-terminal privilege policy.** Acceptance: no privileged
  interactive scenario leaves a hidden/hung process.
- [ ] **Test provider exfiltration minimization.** Acceptance: disabled,
  nonmatching, prefix-only, and restricted-context providers receive no query or
  forbidden context.
- [ ] **Run a final read-only security review after implementation.** Acceptance:
  all P0/P1 findings are resolved before release; accepted lower risks are
  documented with evidence.

### Verification

- [ ] **Add pure unit tests for query, schemas, actions, ranking, flow, policy,
  workflow, metrics, and provider v2.** Acceptance: plausible behavior bugs fail
  specific tests rather than source-text assertions.
- [ ] **Add helper tests for project scan, provider runner, state writers, and
  captured execution.** Acceptance: tests are deterministic, isolated, bounded,
  and full-suite-safe.
- [ ] **Extend live QML smoke coverage.** Acceptance: summon, search, actions,
  argument selection, back navigation, confirm cancel/accept, running success/
  error, and close are exercised against the real shell IPC.
- [ ] **Exercise one real action per migrated source.** Acceptance: apps,
  windows, files, calc, web, shell, system, clipboard, SSH, and providers are
  observed on the actual surface.
- [ ] **Exercise real native examples.** Acceptance: reminder, theme selection,
  screenshot mode, one toggle, audio/brightness adjustment, and long-tail
  discovery use installed Omarchy commands.
- [ ] **Exercise Project Resume repeatedly.** Acceptance: editor/session identity
  proves no duplicate identified windows or tmux sessions.
- [ ] **Verify one light and one dark theme visually.** Acceptance: compact
  layout, breadcrumb, action rows, confirm, running, error, and scroll states are
  readable at the target display scale.
- [ ] **Run `npm test` and `npm run coverage`.** Acceptance: all tests pass and
  statements, branches, functions, and lines remain at least 90%.
- [ ] **Run `omarchy-plugin-validate .`.** Acceptance: validator exits zero from
  a clean checkout.
- [ ] **Run the live plugin IPC smoke after shell restart.** Acceptance:
  `omarchy-shell shell call bitr0t.omnibox ping '{}'` returns `ok` and the QML
  error scan is empty for changed flows.

## Documentation, migration, and release

- [ ] **Update README features and keyboard tables.** Acceptance: actions,
  breadcrumbs, arguments, confirmations, projects, workflows, and provider v2
  match the live implementation.
- [ ] **Document configuration with validated real examples.** Acceptance:
  project roots, workflows, aliases, metrics, provider enablement, and risk
  policies can be copied without placeholders.
- [ ] **Document provider trust prominently.** Acceptance: users are told that
  executable providers are trusted local code with filesystem/network access.
- [ ] **Document state files and privacy contents.** Acceptance: every persisted
  file, mode, allowed fields, reset path, and explicit exclusion is listed.
- [ ] **Document destructive and privileged behavior.** Acceptance: confirmation
  and visible-terminal rules match live behavior.
- [ ] **Document provider v1→v2 migration.** Acceptance: a real current TSV
  example and equivalent validated NDJSON example are shown.
- [ ] **Document rollback for each stage.** Acceptance: a user can return to the
  prior release/config without editing `/usr/share/omarchy` or losing unrelated
  Omarchy configuration.
- [ ] **Update manifest version for the clean provider/API cutover.** Acceptance:
  version communicates the breaking protocol change and matches release notes.
- [ ] **Validate a clean public install.** Acceptance: clone/install from
  `https://github.com/rmacy/omnibox`, enable, bind/summon, test one action flow,
  and remove/restore stock behavior successfully.
- [ ] **Commit and push as the configured user identity.** Acceptance: commit is
  authored by the configured Ryan identity, contains no agent attribution, CI
  passes, and the public branch contains both code and documentation.

## Deferred backlog

These items are intentionally not prerequisites for Omnibox 2.0:

- [ ] LLM or unrestricted natural-language command planning.
- [ ] Browser history or open-tab integration.
- [ ] Email, calendar, contacts, or cloud-service indexing.
- [ ] Semantic/full-content filesystem index.
- [ ] Provider marketplace or automatic third-party installation.
- [ ] Cross-device sync of learning, workflows, aliases, snippets, or metrics.
- [ ] Permanent rich preview pane.
- [ ] Persistent raw shell/provider command history.

Move a deferred item into an active stage only through a PRD revision that
states its user job, privacy boundary, performance budget, safety policy, and
observable acceptance criteria.

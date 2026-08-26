# Omnibox Security Model

This document describes the implemented Omnibox 2.0 trust boundaries. Product
requirements remain in [PRODUCT_REQUIREMENTS.md](./PRODUCT_REQUIREMENTS.md).

## Core invariants

1. Input-derived values become complete argv elements. They are not interpolated
   into `bash -lc` strings.
2. A destructive action requires explicit confirmation regardless of sudo
   metadata or provider claims.
3. Privileged and terminal-interactive actions open in a visible terminal.
4. Raw queries, arguments, clipboard contents, file contents, paths outside the
   approved stable target stores, provider output, and stdout/stderr are not
   metrics.
5. Workflow configuration references registered action IDs. It cannot contain
   argv, shell, or command fields.
6. Provider executables are trusted local code. Triggering, context filtering,
   timeout, and output limits are not a sandbox.
7. Asynchronous results publish only when run serial, query serial, and query
   text still match the latest request.

## Boundary matrix

| Boundary | Trusted input | Untrusted/input-derived data | Execution | Persistence | Controls |
|---|---|---|---|---|---|
| Search sources | First-party code | Query, window titles, filenames, clipboard labels | None while matching | Stable allowlisted targets only | Length/result caps, latest-request-wins |
| `argv` action | Registered action definition | Paths, messages, hosts, selected arguments | `Util.execArgv(argv)` | Stable result/action IDs only | Contract validation, argv count/byte caps |
| Built-in action | First-party dispatcher ID | Validated result values and typed arguments | Fixed dispatcher branch | Stable result/action IDs only | Per-type validation, no dynamic function lookup |
| Expert shell | User explicitly types `>` | Entire command is intentionally shell code | Trusted `bash -lc` boundary | Never learned or pinned with content | Separate mode and visible Shell provenance |
| Native catalog | Installed `omarchy commands --json` | Catalog metadata and typed arguments | argv or visible terminal | Safe no-argument route/action IDs only | Hidden filtering, required-arg parser, independent destructive policy |
| Workflow | Validated registered steps | Selected stable project identity | One registered step at a time | Workflow ID and approved project identity only | Plan preview, confirmation, stop-on-failure, cancel/token checks |
| Provider manifest | Reviewed local manifest | Triggered query body, allowlisted context | Provider executable | None by core learning | Explicit `enabled`, trigger policy, unrestricted allowlist |
| Provider result | Reviewed provider still treated as data producer | NDJSON fields and argv | Validated argv only | Provider result/action content excluded | Namespace, schema, risk override, row/byte/time caps |
| Usage state | Core writer | Stable app/file/system/SSH/native/project/workflow identity | None | `usage.json`, mode `0600` | Versioned sanitizer, exact target writer, atomic replace |
| Project cache | Scanner and Git metadata | Repository names/paths/remotes | None | `projects.json`, mode `0600` | Opt-in roots, depth/cap, credential remote rejection |
| Metrics | Core allowlisted events | Numeric aggregate counts only | None | `metrics.json`, mode `0600` | Pure sanitizer plus independent strict writer schema |

## Provider trust

A provider executable has the same user permissions as Omnibox. Once invoked it
can read user files or access the network. These controls reduce exposure but do
not remove that authority:

- A provider needs a protocol-2 `*.provider.json` manifest and
  `"enabled": true`.
- Triggered providers receive only matching queries. The trigger text is removed
  before `$1` is passed.
- `queryPolicy: "unrestricted"` additionally requires the provider ID in
  `providers.unrestricted` user configuration.
- `$2` contains only manifest-requested fields from the fixed context allowlist.
  Clipboard and file contents are never context.
- The runner independently rechecks manifest enablement, triggers, unrestricted
  allowlisting, executable basename, executable regular-file status, timeouts,
  row caps, and byte caps.
- Provider stdout is line-isolated NDJSON. Core validation rejects shell actions,
  malformed IDs, first-party namespace collisions, invalid lifecycle/risk,
  unconfirmed destructive actions, oversized values, and duplicate actions.
- UI rows and confirmations show provider provenance.

Review both the manifest and executable before enabling a provider.

## Destructive and privileged actions

Risk policy is core-owned; result producers cannot weaken it.

- `risk: destructive` without `confirm: true` is rejected.
- Confirmation identifies the action and target. Provider confirmations include
  provider ID; remote workflows include their concrete registered-step plan.
- `requires_sudo` determines terminal policy only. It is never treated as a
  safety verdict.
- Non-sudo shutdown, reboot, logout, removal, reset, clear, forget, and equivalent
  routes remain confirmed.
- Privileged argv is wrapped as `xdg-terminal-exec -- <argv...>` so the target
  command’s own `sudo`/authentication prompt cannot remain invisible.

## Cancellation and resource bounds

- File and provider searches carry latest-run, query-serial, and active-query
  metadata. Stale output cannot replace current rows.
- Captured actions and workflow steps carry tokens. Stale success/failure is
  ignored.
- Captured actions and workflow steps have 15-second bounds.
- Provider manifests are clamped to 100–5000 ms timeout, 50–1000 ms kill grace,
  1–32 rows, and 256–16384 bytes per physical line.
- Provider processes run concurrently, receive TERM then KILL, and use mode-0600
  temporary files under a mode-0700 directory.
- Project scans are limited to 1–8 levels, 1–500 projects, explicit roots, four
  seconds, and no symlink following.

## Persistent data

| File | Mode | Contents |
|---|---:|---|
| `~/.local/state/omnibox/usage.json` | `0600` | Stable allowlisted target/action IDs, counts, timestamps, pins, user aliases |
| `~/.local/state/omnibox/projects.json` | `0600` | Opt-in project path/name/`.git` marker/branch, normalized credential-free remote, refresh time |
| `~/.local/state/omnibox/metrics.json` | `0600` | Numeric allowlisted counters and latency buckets only |
| `~/.cache/omnibox/packages.tsv` | `0600` | Installed package name/version inventory |

The parent state/cache directories are mode `0700`. Writers reject every other
target and use temporary-file plus atomic-rename replacement.

## Verification map

- `tests/test-actions.js`: action/result bounds, destructive confirmation, shell
  trust, literal metacharacter argv.
- `tests/test-execution.js`: visible-terminal privilege policy, literal argv,
  confirmation and captured-output bounds.
- `tests/test-native.js`: catalog policy, sudo-not-safety, destructive non-sudo
  commands, typed arguments without expansion.
- `tests/test-workflows.js`: registered-only plans, remote credential rejection,
  sequencing, optional/required failure, cancellation and stale tokens.
- `tests/test-provider.js`: manifest/query/context/result/action validation,
  namespace collision prevention and shell-action rejection.
- `tests/test-provider-runner.sh`: trigger isolation, context minimization,
  unrestricted allowlisting, literal query argv, streaming, timeout and cleanup.
- `tests/test-write-metrics.sh`: writer-boundary rejection of content and unknown
  dimensions.
- `tests/test-qml-smoke.sh`: live action/argument/confirmation/result state,
  native policy, Project Resume identity, provider provenance, and metrics UI.

## Final review hardening

The final repository review identified and closed six policy gaps:

- Native catalog refresh/update/install/remove/setup/upgrade/channel/default/pkg
  groups and destructive route keywords are core-classified as confirmed,
  including installed `omarchy refresh pacman`. Typed argv is reclassified
  after argument resolution, so `omarchy snapshot restore`, VM removal, and
  equivalent subcommands cannot inherit a safe base-route policy.
- Provider argv is core-reclassified. Opaque interpreters and process-launching
  wrappers (`timeout`, `nice`, `nohup`, `stdbuf`, scheduling/sandbox launchers,
  BusyBox, and equivalents) are rejected; sudo launchers are forced into a
  visible terminal. Destructive binaries, pacman removal, and destructive
  Omarchy routes are forced to confirmed destructive actions even when provider
  metadata says safe.
- File search uses NUL from `fd`, JSON-encodes each path, decodes each row
  independently, and rechecks configured-root membership. Newline and
  whitespace-bearing filenames cannot create synthetic rows.
- Project scans use queued generations bound to immutable root snapshots.
  Reconfiguration invalidates/stops old work; empty roots publish and persist an
  empty cache; cached/scanned paths must remain under current roots.
- Provider results are rejected by the usage recorder regardless of provider
  result type.
- Metrics action dimensions are composite first-party `source/action` keys.
  Provider actions have aggregate source/type counts only; the independent
  writer rejects provider or mismatched source/action keys.

## Residual risks

- Enabled providers remain fully trusted executable code.
- Explicit `>` shell mode intentionally executes arbitrary user shell input.
- Application/window identity matching is heuristic; it may focus a similarly
  titled window, but it does not grant additional authority.
- Fire-and-forget desktop actions can report successful dispatch, not downstream
  application completion.
- External commands can change behavior after an Omarchy or package update;
  catalog policy and live tests must be rerun for releases.

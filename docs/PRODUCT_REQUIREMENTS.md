# Omnibox 2.0 Product Requirements

**Status:** Proposed  
**Product:** `bitr0t.omnibox`  
**Implementation plan:** [IMPLEMENTATION_TODO.md](./IMPLEMENTATION_TODO.md)

## 1. Executive decision

Omnibox will evolve from a federated search launcher into a local-first
**object → action → argument** workflow surface.

The product already searches applications, windows, files, calculations, the
web, shell commands, system actions, clipboard history, SSH hosts, and external
providers. More flat sources would increase result volume without addressing
the main limitation: a result currently carries one `kind` and one payload,
and activation immediately closes the launcher and dispatches that single
operation.[^current-row][^current-activation]

The compounding product primitive is therefore:

```text
Find an object → choose an action → supply typed arguments → confirm if needed
→ execute → show the result
```

Every existing source must adopt this model before unrelated sources are added.

## 2. Problem statement

### 2.1 Current behavior

The current implementation is effective at finding targets but weak at acting
on them:

1. `makeRow(...)` stores one `kind` and one `data` value.[^current-row]
2. The display model reduces those fields to one `kind` and one `payload`.[^display-model]
3. `activateIndex(...)` closes Omnibox before dispatching a hard-coded branch.[^current-activation]
4. File reveal is a special `Alt+Enter` case rather than a general action.[^file-special-case]
5. Results are sorted within fixed source buckets, then concatenated in
   `sourceOrder`; scores are not comparable across sources.[^fixed-ranking]
6. Providers return an opaque executable action through a TSV row, which cannot
   express typed arguments, confirmation, progress, or multiple actions.[^provider-current]
7. Learned ranking is deliberately limited to stable apps, files, system
   actions, and SSH hosts. That privacy boundary is valuable, but the stored
   action is not independently learnable or pinnable.[^learning-current]

### 2.2 User cost

A user can find a file, window, project, or host quickly, but many common jobs
still require opening another application or terminal and reconstructing the
same context. Examples:

- Find a file, then open another terminal to work in its directory.
- Find a window, then use separate Hyprland bindings to move or resize it.
- Find an SSH host, then separately copy its name or transfer a file.
- Open the theme or capture picker instead of expressing the desired option.
- Reopen an editor, terminal, tmux session, and browser page to resume a project.

The product is useful as a launcher. The opportunity is to make it the shortest
path from intent to completed desktop workflow.

## 3. Goals

### G1 — Multiply the value of current results

Every first-party result type must expose a primary action and a discoverable
set of secondary actions.

### G2 — Make Omarchy capabilities discoverable

Omnibox must index the machine-readable command catalog exposed by
`omarchy commands --json` and provide safe direct execution for eligible
commands.[^command-catalog]

### G3 — Replace repeated multi-step rituals

Omnibox must support typed, deterministic workflows. Project Resume is the
first reference workflow.

### G4 — Preserve speed and local-first privacy

The launcher must remain daemon-free, responsive, bounded, and usable without a
network connection. Raw queries, arguments, clipboard contents, and file
contents must not be recorded as usage metrics.

### G5 — Make execution trustworthy

Input-derived values must be passed as argv elements, failures must be visible,
and destructive or privileged actions must have explicit execution policies.

### G6 — Delegate explicit LLM jobs to Omarchy

Omnibox must offer an explicit `? <prompt>` mode that delegates to the
user-configured Omarchy default coding agent. Omnibox does not choose a model,
translate the response into its own actions, or start an agent for an
unprefixed query.

## 4. Non-goals

The initial Omnibox 2.0 scope does **not** include:

- Automatic or silent conversion of unprefixed natural language into shell
  commands or Omnibox actions.
- Browser-history scraping, email, calendar, or cloud-account indexing.
- Semantic filesystem indexing or a background content-indexing daemon.
- A provider marketplace or automatic installation of third-party providers.
- Cross-device synchronization of usage, snippets, aliases, or workflows.
- A permanently expanded preview pane.
- Persistent raw shell-command or provider-action history.
- Silent retries, rollback claims, or workflow continuation after an
  unhandled failed step.

These features add privacy, latency, or supply-chain cost before the core action
model is proven.

## 5. Users and jobs

### 5.1 Primary user

A keyboard-oriented Omarchy user who frequently switches among applications,
windows, files, terminals, projects, and system controls.

### 5.2 Core jobs

1. **Act on a known object:** “Find this file and open a terminal beside it.”
2. **Control the desktop:** “Move this window,” “stay awake,” or “capture a
   region” without recalling a keybinding or CLI route.
3. **Resume work:** restore the applications and context for a project without
   duplicating existing windows or sessions.
4. **Discover a capability:** find an Omarchy command by its human summary.
5. **Repeat a stable action:** pin or alias a safe object/action pair without
   storing sensitive input.
6. **Extend locally:** add trusted typed results and actions without modifying
   the core QML file.
7. **Delegate an open-ended job:** explicitly hand a prompt to the configured
   Omarchy agent without opening a terminal and retyping it.

## 6. Product principles

1. **Primary action stays fast.** `Enter` always performs the selected result’s
   primary action when no argument or confirmation is required.
2. **Secondary actions are visible, not memorized.** The UI must advertise the
   action key for the selected row.
3. **Arguments are typed.** A device picker, theme picker, workspace picker, or
   validated integer is preferable to a free-form shell fragment.
4. **Execution is inspectable.** Confirmation shows the concrete operation.
5. **Escape reverses navigation.** It pops one workflow level before clearing
   the search or closing the launcher.
6. **No hidden failure.** An action that can fail must report success or error.
7. **Exact intent beats category order.** A strong system/file/window match may
   rank above a weak application match.
8. **Privacy is a feature.** Learning stores stable identifiers, not content.
9. **Providers are trusted code.** Their trust boundary must be explicit.
10. **Boring implementation wins.** Reuse Quickshell, Omarchy CLI contracts,
    and the existing latest-request-wins process lifecycle; add no daemon.
11. **Agent delegation is explicit.** Only the `?` prefix crosses the LLM trust
    boundary; Omnibox reuses Omarchy’s configured agent and launcher unchanged.

## 7. Interaction requirements

### 7.1 Modes and navigation

Omnibox must implement this bounded state flow:

```text
Search → Actions → Arguments → Confirm → Running → Result
```

Requirements:

- The stack depth must be bounded to four interactive levels.
- A breadcrumb must show the selected object and each active step.
- `Escape` pops the current level.
- `Escape` in Search clears a non-empty query; a second `Escape` closes, matching
  current behavior.[^current-keys]
- Clearing or popping a level must cancel stale asynchronous work through the
  existing query-serial/latest-run mechanism.[^async-current]
- Returning to a prior level must restore the stable selected result when it
  still exists.

### 7.2 Keyboard contract

| Key | Search | Actions / Arguments / Confirm |
|---|---|---|
| `Enter` | Run primary action or advance to its first argument | Select/advance/confirm |
| `Tab` or `Ctrl+K` | Open actions for selected result | Move to the next declared field only when unambiguous |
| `Shift+Tab` | No action | Move to the previous field/level |
| `Up` / `Down` | Move selection | Move selection |
| `PageUp` / `PageDown` | Move by page | Move by page |
| `Alt+Enter` | Existing file Reveal shortcut | Optional action-specific shortcut |
| `Escape` | Clear, then close | Pop one level |

The implementation must select either `Tab` or `Ctrl+K` as the documented
canonical action key after live usability testing. Supporting both is allowed
when neither conflicts with text input or accessibility behavior. The current
key handler has no Tab/Ctrl+K branch and is the integration seam.[^current-keys]

### 7.3 Breadcrumb example

```text
omnibox.jsonc › Send to device › desktop
```

The search field edits only the active level. Back-navigation must not require
retyping `omnibox.jsonc`.

### 7.4 Action feedback

Actions must declare one of these lifecycle policies:

- `close`: fire-and-forget only when success is observable elsewhere, such as
  focusing a window.
- `keepOpen`: show Running, then Success or Error inside Omnibox.
- `terminal`: close Omnibox and start the operation in a visible terminal.

Errors must include the action title, exit status, and bounded stderr. Secrets
and raw clipboard contents must be redacted from displayed command plans and
logs.

## 8. Functional requirements

### FR1 — Typed Result and Action model

Every displayed row must be backed by a `Result` with stable identity and an
ordered action list.

**Proposed internal contract — illustrative, not current code:**

```js
var result = {
  id: "file:/home/ryan/Documents/notes.txt",
  type: "file",
  source: "files",
  title: "notes.txt",
  subtitle: "~/Documents/notes.txt",
  value: { path: "/home/ryan/Documents/notes.txt" },
  score: 12,
  actions: [
    {
      id: "file.open",
      title: "Open",
      executor: "argv",
      argv: ["xdg-open", "/home/ryan/Documents/notes.txt"],
      close: true
    },
    {
      id: "file.edit",
      title: "Open in editor",
      executor: "argv",
      argv: ["omarchy", "launch", "editor", "/home/ryan/Documents/notes.txt"],
      close: true
    },
    {
      id: "file.copy-path",
      title: "Copy path",
      executor: "copyText",
      text: "/home/ryan/Documents/notes.txt",
      keepOpen: true
    }
  ]
}
```

The concrete `argv` arrays above are directly executable examples. Dynamic
values must be appended as complete argv elements; implementations must not
construct shell fragments from `result.value`.

The model must support at least:

- `id`, `type`, `source`, `title`, `subtitle`, icon metadata, `value`, and score.
- Ordered `actions[]`; index zero is the primary action.
- Stable action IDs suitable for safe learning.
- `argv`, built-in, and workflow action executors.
- Typed arguments, confirmation policy, lifecycle policy, and risk metadata.

All existing app, window, file, calculation, web, shell, system, clipboard,
SSH, and provider call sites must migrate. The old single `kind`/`payload`
dispatch path must then be removed rather than retained as an alias.

### FR2 — Action palette coverage

Minimum first-party coverage:

| Type | Required actions |
|---|---|
| App | Open/focus, launch new, pin/unpin |
| Window | Focus, move to workspace, move to monitor, toggle floating/fullscreen, close with confirmation |
| File | Open, reveal, edit, terminal in containing directory, copy path, send to Taildrop device when available |
| Calculation | Copy result, paste result |
| Web query/URL | Open with default engine/browser, choose configured engine, copy URL |
| Clipboard text | Paste, copy again, pin as non-secret snippet only after explicit confirmation |
| Clipboard image | Copy again, open |
| SSH host | Connect, copy host, choose a file and send when a supported transfer action exists |
| System command | Run, inspect usage/example, pin when safe |
| Project | Resume, open editor, open terminal, search files, copy path, open Git remote when known |

Actions unavailable on the current machine must be omitted, not disabled rows
that fail on activation.

### FR3 — Native Omarchy command catalog

On first use after shell start, and after an explicit refresh, Omnibox must run:

```bash
omarchy commands --json
```

The installed Omarchy command center documents this as the machine-readable
catalog and emits `route`, `binary`, `group`, `name`, `summary`,
`requires_sudo`, `hidden`, `args`, `examples`, `aliases`, and routes.[^command-catalog]

Current installation evidence:

```console
$ omarchy commands --json | jq '.commands | length'
356
```

Requirements:

- Cache the parsed catalog in memory; do not run it per keystroke.
- Exclude `hidden` commands by default.
- Search human summary, route, aliases, arguments, and examples.
- Never infer that `requires_sudo: false` means non-destructive.
- Use a curated risk-policy map for destructive, privileged, interactive, and
  terminal-required commands.
- Directly execute only commands whose required arguments are fully resolved.
- For unresolved commands, enter typed argument mode or show usage/examples;
  do not run a command with missing required arguments as an implicit help
  mechanism.
- High-frequency commands may have explicit parsers and pickers. The generic
  catalog remains the long-tail discovery path.

### FR4 — Deterministic typed command adapters

The following intents must be supported without an LLM:

#### Reminder

User query:

```text
remind 20 check oven
```

Concrete execution:

```bash
omarchy reminder 20 "Check oven"
```

The installed command accepts `<minutes> [message]`, exposes JSON listing, and
validates positive integer minutes.[^reminder]

Acceptance:

- Minutes must be a positive integer before an action row appears.
- The result title must state the delay and message.
- The action must pass the message as one argv element.

#### Theme

User query:

```text
theme tokyo night
```

Concrete discovery and execution:

```bash
omarchy theme list
omarchy theme set "Tokyo Night"
```

The theme list prints installed user and stock themes; theme set requires one
theme name.[^theme-list][^theme-set]

Acceptance:

- Values must come from the live theme list.
- A partial query must fuzzy-match themes.
- Applying a theme uses the selected full theme name as one argv element.

#### Capture

User query:

```text
screenshot region
```

Preferred execution when Omasnap is available:

```bash
omasnap region --copy
```

Fallback through the system’s Omarchy capture command:

```bash
omarchy capture screenshot region copy
```

The action picker must expose `smart`, `region`, `windows`, and `fullscreen`
plus edit/copy/save. Omasnap is selected from an observed executable-availability
state; otherwise Omarchy’s default capture route is used.[^omasnap][^capture]

#### Desktop toggles and adjustments

Concrete supported Omarchy commands include:

```bash
omarchy toggle idle stay-awake
omarchy toggle nightlight
omarchy toggle notification silencing
omarchy audio output volume +10
omarchy brightness display +10%
```

The result row must state the target state or adjustment. Toggle actions must
query and display state where Omarchy exposes a cheap state seam; they must not
claim a state that was not observed.

### FR5 — Global ranking, pins, aliases, and empty state

All sources must produce a comparable score. The ranker must consider:

1. Exact label/alias match.
2. Prefix and word-boundary match.
3. Fuzzy score.
4. Explicit query intent or active mode.
5. Explicit pin.
6. Frequency with a bounded boost.
7. Recency decay.
8. Small source priors only as tie-breakers.

Requirements:

- Fixed bucket concatenation must be removed.[^fixed-ranking]
- Source information remains visible as a badge or subtitle.
- Exact system/file/window matches may outrank weak app matches.
- Users can Pin, Unpin, Set alias, Forget, and Reset learning.
- Empty search shows Pinned, recent safe actions, then deterministic suggestions.
- Store only stable result/action/workflow IDs, counts, timestamps, and
  user-authored aliases.
- Never store raw queries, arbitrary argv, clipboard text, calculation input,
  file contents, or provider output snapshots.
- If an object disappears, its learned entry must fail closed and be eligible
  for aging/removal.

### FR6 — Projects and Project Resume

Projects are directories under explicit configured roots. A project is
recognized by configured markers, initially `.git`.

**Proposed configuration — not a current option:**

```jsonc
{
  "projects": {
    "roots": ["~/Code", "~/.config/omarchy/plugins"],
    "maxDepth": 4
  }
}
```

Requirements:

- Project roots are opt-in; Omnibox must not crawl `$HOME` by default.
- Scan outside the keystroke path and cache only stable project metadata with
  mode `0600` under the existing Omnibox state directory.
- Refresh through bounded filesystem observation or explicit refresh.
- Project rows show name, shortened path, and Git branch when cheaply available.
- The real Omarchy editor seam is:

  ```bash
  omarchy launch editor /home/ryan/.config/omarchy/plugins/bitr0t.omnibox
  ```

  `omarchy-launch-editor` accepts `[--inline] <path>` and executes the selected
  editor with the path as an argv element.[^launch-editor]
- Terminal and tmux steps are optional capabilities detected on the machine.
- Resume must focus existing matching windows/sessions before launching new
  ones where a deterministic identity exists.
- Resume must not duplicate an editor or tmux session during repeated execution.

### FR7 — Deterministic workflows

A workflow is a stable ID, typed parameters, and ordered references to
registered actions.

**Proposed configuration — not a current option:**

```jsonc
{
  "workflows": [
    {
      "id": "project.resume.omnibox",
      "title": "Resume Omnibox",
      "aliases": ["omni", "omnibox project"],
      "parameters": [
        { "name": "project", "type": "project", "required": true }
      ],
      "steps": [
        { "action": "project.open-or-focus-editor" },
        { "action": "project.open-or-focus-terminal" },
        { "action": "project.open-git-remote", "optional": true }
      ],
      "stopOnFailure": true
    }
  ]
}
```

Requirements:

- Each step references a registered typed action; it does not contain an
  arbitrary interpolated shell string.
- Show the concrete plan before any destructive or remote workflow.
- Stop on first non-optional failure.
- No silent retry.
- Cancellation stops the active process and prevents later steps from starting.
- Progress identifies the current step.
- Usage records the workflow ID only, never parameter values.

### FR8 — Typed provider protocol

The pre-v2 provider protocol executed every discovered provider for each
non-empty non-shell query and passed the raw query as `$1`; time and output
limits constrained resources but did not sandbox provider filesystem or network
access.[^provider-query][^provider-runner]

Protocol 2 is a clean cutover to manifest-gated newline-delimited JSON with
stable namespaced results and typed argv actions. Trigger policies and explicit
unrestricted-provider allowlisting decide whether a provider receives a query.

**Implemented provider output — concrete argv:**

```json
{"protocol":2,"id":"project:omnibox","type":"project","title":"Omnibox","subtitle":"~/.config/omarchy/plugins/bitr0t.omnibox","value":{"path":"/home/ryan/.config/omarchy/plugins/bitr0t.omnibox"},"actions":[{"id":"project.edit","title":"Open in editor","executor":"argv","argv":["omarchy","launch","editor","/home/ryan/.config/omarchy/plugins/bitr0t.omnibox"],"lifecycle":"close","risk":"safe"}]}
```

Taildrop’s installed command contract accepts `<machine> [file...]`; the
machine name below is the command’s shipped example value:[^taildrop]

```bash
omarchy tailscale send dhh-fd \
  /home/ryan/.config/omarchy/plugins/bitr0t.omnibox/README.md
```

Provider requirements:

- A manifest declares protocol version, stable provider ID, trigger terms or
  prefix, capabilities, and whether unrestricted queries are required.
- Providers receive a query only when enabled and their trigger policy allows
  it.
- Provider provenance is visible in the UI.
- IDs, field lengths, row counts, process duration, and output bytes remain
  bounded.
- `argv` must be an array of bounded strings; no implicit shell parsing.
- Shell actions are allowed only for explicitly trusted local workflow
  definitions and must be labeled as shell actions in confirmation UI.
- Unknown fields are ignored; invalid required fields reject the row.
- A malformed provider cannot mutate another provider’s rows.
- Clipboard content and file contents are never added to provider context by
  default.

### FR9 — Safe execution

For any action containing input-derived values, use the real Omarchy shell
utility `Util.execArgv(argv)`. It executes positional parameters without shell
re-tokenization and is explicitly preferred over `execDetached` for untrusted
input.[^exec-argv]

**Real QML API example:**

```qml
Util.execArgv([
  "omarchy",
  "launch",
  "editor",
  result.value.path
])
```

Rules:

- No string concatenation into `bash -lc` for result values, provider fields,
  query text, paths, aliases, messages, host names, or workflow arguments.
- Built-in text copy must use a process with stdin or another argv-safe helper;
  it must not create a shell pipeline from text.
- Destructive actions enter Confirm and require a second explicit `Enter`.
- Confirmation names the target and operation.
- Privileged interactive actions launch in a visible terminal so the user can
  respond to `sudo`; they must not start a hidden password prompt.
- Arbitrary `>command` remains an explicit expert mode and retains its distinct
  trust boundary. It is never learned or pinned with raw contents.

### FR10 — Context capture

On open, Omnibox may capture bounded metadata:

- Focused window address, class, title, workspace, and monitor.
- Current time.
- Clipboard availability/type, but not clipboard content for provider context.

Requirements:

- Capture is asynchronous or uses already-cached shell state.
- Context improves actions and ranking but cannot delay the initial cached
  result render.
- Context is scoped to one Omnibox session and is not persisted.
- Providers receive no context unless their manifest requests an allowed field.

### FR11 — Local aggregate metrics

Metrics exist to test the product decision, not observe user content.

Allowed aggregate counters/histograms:

- Opens, closes, cancellations, and successful/failed activations.
- Selected source/type/action ID from a first-party stable allowlist.
- Whether rank one was used or selection moved.
- Mode transitions and secondary-action use.
- Bounded summon-to-completion and input-to-render latency buckets.
- Workflow step count and success/failure count.

Forbidden data:

- Query text or query hashes.
- Clipboard text/images.
- File paths, titles, contents, or shell commands.
- Provider labels/output.
- Workflow arguments.
- SSH host names or remote command arguments.

Metrics remain local, mode `0600`, inspectable, resettable, and disabled by one
configuration flag.

### FR12 — Explicit default-agent delegation

An agent prompt is recognized only when the trimmed query begins with `?`.
The remaining text is passed as one argv element:

```bash
omarchy agent prompt "<prompt>"
```

Requirements:

- Agent mode produces one stable first-party native result; its ID and action
  ID contain no prompt content.
- The prompt is never sent to file search, providers, learning, aliases, pins,
  recents, or detailed action metrics.
- The row is built synchronously. No model or agent process starts while the
  user types.
- Every installed `omarchy agent...` route is reserved from generic catalog
  search and cached learning; only Agent mode may expose a launcher route.
- A configured prompt’s activation always enters Confirm. Confirmation states
  that Omarchy launches the configured agent with unattended permissions and
  shows a bounded single-line plain-text prompt preview.
- Confirmed activation delegates through `omarchy agent prompt` with lifecycle
  `close`; that installed launcher opens the visible agent terminal itself, so
  Omnibox does not add a redundant terminal wrapper or invoke an agent binary.
- `$()`, backticks, quotes, semicolons, newlines, and leading dashes remain
  literal prompt data rather than shell syntax.
- If no default agent is configured, the row offers the installed
  `omarchy agent --pick` setup path instead of pretending the prompt ran.
- Omnibox does not capture the response, parse proposed commands, silently
  execute a plan, or persist conversation content.
- Prompt labels and confirmation details render as plain text; rich-text tags or
  remote resource references are never interpreted by QML.

Privacy boundary: prompt text leaves Omnibox only after explicit confirmation
and is then governed by the configured agent’s filesystem, network, account,
and retention policies. Performance budget: parsing and row construction stay
inside the cached-source render budget; agent startup is user-triggered and
excluded from local completion-latency goals.

## 9. Performance requirements

1. Cached sources render before asynchronous providers or file search complete.
2. Keystroke-to-render for cached sources: p95 below 50 ms on the target system.
3. First useful asynchronous batch: p95 below 350 ms for built-in local sources.
4. `omarchy commands --json` runs once per shell lifetime or explicit refresh,
   not once per query.
5. Project scans and provider processes never run on the QML/UI thread.
6. Existing latest-request-wins cancellation remains the invariant for query,
   file, provider, and catalog work.[^async-current]
7. Every process has a bounded runtime and output size.
8. The action/navigation stack is bounded to four levels.
9. No new daemon or resident indexer is introduced.

## 10. Accessibility and visual requirements

- Keyboard-only operation must cover every flow.
- Mouse selection must continue using the existing pointer movement gate.
- Selected, running, successful, warning, and destructive states must not rely
  on color alone.
- Action hints and breadcrumbs must elide safely within the existing compact
  card.
- The action palette should reuse the current list surface rather than add a
  permanently visible second panel.
- Light and dark Omarchy themes must preserve readable selected and destructive
  states.

## 11. Delivery stages and gates

### Stage A — Action kernel

Scope:

- Typed Result/Action model.
- Search/Actions/Arguments/Confirm/Running/Result state controller.
- Action palette, breadcrumbs, execution feedback, and argv-safe executor.
- Migration of every current first-party source.
- Global ranking, pins, aliases, and safe learning migration.

Gate: all current launcher behavior remains available through the new model;
secondary file/window/app/clipboard/SSH actions work live; the obsolete
single-kind dispatcher is removed.

### Stage B — Native Omarchy control

Scope:

- Cached command catalog.
- Conservative policy classification.
- Reminder, theme, capture, toggle, audio, and brightness adapters.
- Long-tail command discovery and typed argument flow.

Gate: a user can complete the documented real command examples without opening
another picker or manually typing a shell command; destructive and privileged
policies are exercised live.

### Stage C — Projects and workflows

Scope:

- Opt-in project index.
- Project action palette and idempotent Project Resume.
- Typed workflow configuration and execution controller.

Gate: Project Resume replaces at least four manual steps and repeated execution
does not create duplicate identified windows or sessions.

### Stage D — Extension platform

Scope:

- Provider manifests and versioned NDJSON.
- Typed provider actions, triggers, provenance, and context policy.
- Migration of the shipped provider and user documentation.

Gate: the TSV path is removed, malformed/adversarial providers are bounded, and
no provider receives an unrestricted query without explicit policy.

### Stage E — Default-agent delegation

Scope:

- Explicit `?` query mode.
- Default-agent discovery through installed Omarchy commands.
- Confirmed visible-terminal delegation with prompt isolation.

Gate: a literal prompt reaches `omarchy agent prompt` as one argv element only
after Confirm; unrelated sources receive nothing; no prompt content enters
usage or metrics; unset-agent setup and configured-agent flows pass live.

## 12. Product acceptance metrics

All metrics are computed locally from aggregate-only data.

1. At least 20% of successful sessions use a non-primary action after the
   feature has enough repeat usage to measure.
2. Median direct-action summon-to-completion time is below two seconds on the
   target workstation.
3. Selection-correction rate for repeat targets falls by 50% from the local
   pre-release baseline.
4. At least one repeated workflow replaces four or more manual steps and is
   successfully reused on three separate days.
5. Action-mode cancellation remains below 10% after discovery/onboarding use is
   excluded.
6. No destructive action executes without entering Confirm.
7. No privileged action starts an invisible password prompt.
8. No raw query, argument, clipboard content, file content, or provider output
   appears in usage or metrics state.
9. Every non-fire-and-forget action failure is visible to the user.
10. Existing JS coverage gates, shell helper tests, plugin validation, and live
    QML smoke checks continue to pass.

These are product validation thresholds, not remote telemetry requirements.

## 13. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Action UI makes the launcher slower | Render cached Search first; lazy-build actions for the selected result |
| Too many actions become noisy | Ordered type defaults; machine-capability filtering; primary action stays Enter |
| Global ranking destabilizes familiar results | Deterministic score components, fixtures, pins, and inspectable local learning |
| Command catalog contains dangerous/interactive entries | Conservative allowlist plus explicit risk policy; catalog metadata is not treated as a safety verdict |
| Input becomes shell code | `Util.execArgv`, typed built-ins, and no interpolation into shell strings |
| Provider exfiltrates queries | Explicit trust documentation, trigger policy, enablement, provenance, and minimal context |
| Workflows partially complete | Visible step status, stop on failure, cancel, and no silent retry |
| Project scan becomes expensive | Explicit roots, bounded depth, cached metadata, background scan |
| Learning stores sensitive values | Stable IDs only, category allowlist, inspect/reset controls |
| QML monolith becomes unmaintainable | Extract pure query/ranking/action/workflow logic into tested ES5-compatible JS modules; keep process/UI wiring in QML |

## 14. Product decisions

Resolved through the Stage A live prototype:

1. `Tab` is the canonical action key; `Ctrl+K` is an equivalent alternate.
2. `Alt+Enter` remains the direct Reveal shortcut for file results.
3. Safe stable action IDs enter local recency learning after activation; pins
   remain explicit.
4. The portable first-party window set is Focus, move to workspace, move to
   next/previous monitor, toggle floating, tiled fullscreen, and confirmed
   close through Omarchy’s Hyprland Lua dispatcher surface.

Resolved implementation decisions:

5. Provider v2 is a major-version clean cutover using sibling
   `*.provider.json` manifests and typed NDJSON. There is no runtime TSV or
   dual-protocol compatibility path.
6. Aggregate metrics are enabled by default, local-only, inspectable, resettable,
   and disabled with `metrics.enabled: false`. The writer accepts only numeric
   allowlisted aggregate dimensions; content is forbidden.

## 15. Source citations

[^current-row]: Pre-v2 one-operation row schema: [`Omnibox.qml` lines 385–397](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L385-L397).
[^display-model]: Pre-v2 display projection to `kind` and `payload`: [`Omnibox.qml` lines 943–953](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L943-L953).
[^current-activation]: Pre-v2 activation closed the launcher and dispatched by `kind`: [`Omnibox.qml` lines 1038–1089](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L1038-L1089).
[^file-special-case]: Pre-v2 `Alt` file Reveal branch: [`Omnibox.qml` lines 1053–1078](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L1053-L1078).
[^fixed-ranking]: Pre-v2 fixed source order and per-bucket concatenation: [`Omnibox.qml` lines 873–924](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L873-L924).
[^provider-current]: Pre-v2 TSV provider contract and opaque executable action: [`Omnibox.qml` lines 731–736 and 823–860](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L731-L860).
[^learning-current]: Pre-v2 stable usage allowlist and identity validation: [`Omnibox.qml` lines 150–207](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L150-L207).
[^current-keys]: Pre-v2 key handling for Escape, navigation, paging, and Enter: [`Omnibox.qml` lines 1549–1590](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L1549-L1590).
[^async-current]: Pre-v2 query serial, pending-run, and stale-result cancellation: [`Omnibox.qml` lines 69–79](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L69-L79), [979–990](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L979-L990), and [1132–1184](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L1132-L1184).
[^provider-query]: Pre-v2 provider invocation passed every query to every executable: [`Omnibox.qml` lines 774–799](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/Omnibox.qml#L774-L799).
[^provider-runner]: Pre-v2 provider runner resource bounds without sandboxing: [`bin/run-providers` lines 40–125](https://github.com/rmacy/omnibox/blob/a94fe24c7a9d29db06ca1c8d7d5300d15bcc467c/bin/run-providers#L40-L125).
[^exec-argv]: Installed Omarchy argv-safe execution contract: `/usr/share/omarchy/shell/Commons/Util.qml`, lines 57–63.
[^command-catalog]: Installed Omarchy command discovery and JSON schema: `/usr/share/omarchy/bin/omarchy`, lines 538–555 and 669–684.
[^reminder]: Installed reminder metadata, validation, and execution: `/usr/share/omarchy/bin/omarchy-reminder`, lines 3–5, 135–139, and 168–198.
[^theme-list]: Installed theme enumeration: `/usr/share/omarchy/bin/omarchy-theme-list`, lines 3–9.
[^theme-set]: Installed theme application contract: `/usr/share/omarchy/bin/omarchy-theme-set`, lines 3–8.
[^capture]: Live `omarchy commands --json` entry for route `omarchy capture screenshot`; its declared args are `[smart|region|windows|fullscreen] [slurp|copy|save] [--editor=<name>]`.
[^launch-editor]: Installed default-editor launcher: `/usr/share/omarchy/bin/omarchy-launch-editor`, lines 3–4 and 25–32.
[^taildrop]: Installed Taildrop command contract: `/usr/share/omarchy/bin/omarchy-tailscale-send`, lines 3–10.
[^omasnap]: Installed Omasnap CLI contract from `omasnap --help`: targets `smart|region|windows|fullscreen`; `--copy` and `--save` bypass the editor, while no output flag opens annotation.

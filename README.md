# Omnibox — an Alfred-style universal launcher for Omarchy

One box for everything on your Omarchy desktop. Press **Super + Space**, type,
hit Enter.

Omnibox is a `kind: "menu"` plugin for the Omarchy shell (Quickshell). It runs
inside the long-lived `omarchy-shell` process — no extra daemons — and shows
ranked results from ten sources as you type:

| Source | What it does |
|---|---|
| **Apps** | Fuzzy-search every installed app (real icons, keywords, GenericName) and launch it |
| **Windows** | Search your open Hyprland windows by title/class and jump to them |
| **Files** | Live `fd` search across your XDG dirs; Enter opens, **Alt+Enter** reveals in the file manager |
| **Calculator** | Type math: `=2+2*10`, `10% of 200`, `sqrt(16)`, `2pi`, `sin(30)` — Enter copies the result |
| **Web** | Search DuckDuckGo, Google, YouTube, GitHub, Arch Wiki; bare URLs open directly |
| **Shell** | Prefix `>` to run a command in a terminal or in the background |
| **System** | Lock, suspend, logout, reboot, shutdown, menu routes, and learned-state controls |
| **Omarchy commands** | Search the live `omarchy commands --json` catalog and run policy-gated native actions |
| **Clipboard** | Search your Omarchy clipboard history; Enter pastes into the focused window |
| **SSH** | Hosts from `~/.ssh/config`; Enter opens an `ssh` session in your terminal |
| **Projects** | Search opt-in Git repositories; resume, edit, open a terminal, scope file search, copy path, or open the remote |
| **Workflows** | Run validated registered-action workflows with typed project arguments, progress, cancellation, and stop-on-failure |
| **Providers** | Manifest-gated trusted executables that stream typed protocol-2 NDJSON results and argv actions |

Screenshot actions check at execution time and use `omasnap` whenever it is
available. Otherwise they invoke Omarchy’s system-default `omarchy screenshot`
capture tool. Mode and edit/copy/save are selected inside the action flow.

Every result has a primary action plus a discoverable action palette. Press
**Tab** or **Ctrl+K** to act on a selected app, window, file, calculation, URL,
clipboard entry, system command, or SSH host without rebuilding context in
another app. Breadcrumbs preserve the selected object while arguments and
confirmations are collected.

Omnibox also **learns stable targets and actions**: frequently and recently
used apps, files, system actions, and SSH hosts float to the top. Safe targets
can be pinned, aliased, forgotten, inspected, or reset from the action palette.
Shell commands, provider actions, clipboard entries, calculations, and web
queries are never persisted. Versioned usage state is stored atomically with
mode `0600`. Open the box with an empty query to see pinned and recent targets
followed by deterministic system suggestions.

The stock Omarchy menu is untouched — every `omarchy menu toggle <route>`
(system, capture, theme, setup, …) keeps working, and Omnibox links into it.

## Install

Requires Omarchy 4.x (tested on 4.0.0). `fd` is recommended for file search
(preinstalled on Omarchy).

```bash
omarchy plugin add https://github.com/rmacy/omnibox --enable
```

Then bind a key. Add to `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + SPACE")
o.bind("SUPER + SPACE", "Omnibox launcher", "omarchy-shell shell toggle bitr0t.omnibox")
```

Hyprland reloads bindings on save. If Super+Space still opens the stock menu
in your current session, log out and back in once — Hyprland's Lua binding
table is rebuilt at session start.

Manual summon from anywhere:

```bash
omarchy-shell shell summon bitr0t.omnibox '{"query":"ghost"}'
```

### Update

```bash
omarchy plugin update bitr0t.omnibox
```

### Roll back a release or stage

Back up Omnibox-only state first; older releases do not understand every v2
state envelope:

```bash
cp -a ~/.local/state/omnibox ~/.local/state/omnibox.rollback-backup
git -C ~/.config/omarchy/plugins/bitr0t.omnibox fetch --tags origin
```

Then check out the required release/stage and restart only the shell:

| Target | Git ref |
|---|---|
| Last protocol-1 release | `v1.1.0` |
| Action kernel | `f3653bd` |
| Native Omarchy controls | `b113920` |
| Projects and workflows | `0a20a05` |
| Provider v2 platform | `e642ed9` |
| Current v2 release | `v2.0.0` |

```bash
git -C ~/.config/omarchy/plugins/bitr0t.omnibox checkout v1.1.0
omarchy restart shell
```

Return to the update channel with `git checkout main` followed by
`omarchy plugin update bitr0t.omnibox`. Rollback never edits
`/usr/share/omarchy` or unrelated Omarchy configuration. Extra v2 JSONC keys are
ignored by older plugin code.

### Remove and restore the stock launcher

First remove these two lines from `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + SPACE")
o.bind("SUPER + SPACE", "Omnibox launcher", "omarchy-shell shell toggle bitr0t.omnibox")
```

Then reload Hyprland and remove the plugin:

```bash
hyprctl reload
omarchy plugin remove bitr0t.omnibox
```

The default Omarchy `SUPER + SPACE` binding becomes active again because the
user override no longer unbinds it. Omnibox never modifies the stock menu
root or bar button. Optionally delete learned state:

```bash
rm -rf ~/.local/state/omnibox
```

## Keys

| Key | Action |
|---|---|
| Type | Query all sources |
| ↑ / ↓, PgUp / PgDn | Move selection |
| Enter | Run the primary action or select the current action/argument |
| Tab, Ctrl+K | Open the selected result’s action palette |
| Shift+Tab | Return one action/argument level |
| Alt+Enter | On file rows: open the containing folder |
| Escape | Return one level; in search, clear query then close |

## Prefixes

| Prefix | Meaning |
|---|---|
| `>` | Shell command (`>uname -a` → run in terminal / background) |
| `=` | Force calculator (`=42*2`) |
| none | Apps, windows, files, math auto-detect, web, everything |

## Native intents

The command catalog is cached once per shell lifetime. High-frequency commands
have deterministic typed adapters; the remaining visible catalog stays
searchable by route, summary, aliases, arguments, and examples.

```text
remind 20 Check oven
show reminders
theme bauhaus
screenshot
stay awake
night light
bluetooth off
volume +10
brightness 50
text size 14
background next
```

Commands with unresolved arguments enter argument mode. Destructive actions
enter confirmation mode. Privileged and terminal-interactive commands open in
a visible terminal; `requires_sudo: false` is never treated as proof that an
action is safe.

## Configuration

Optional: `~/.config/omarchy/extensions/omnibox.jsonc` (hot-reloads):

```jsonc
{
  // Web search engines; the first entry is the default. %s = query.
  "engines": {
    "DuckDuckGo": "https://duckduckgo.com/?q=%s",
    "Google": "https://www.google.com/search?q=%s"
  },
  // Roots for file search (leading ~ expands).
  "fileRoots": ["~/Documents", "~/Downloads", "~/Desktop",
                "~/Pictures", "~/Videos", "~/Music"],
  // Max rows per source.
  "maxResults": 8,
  // Project discovery is opt-in and bounded.
  "projects": {
    "roots": ["~/Projects", "~/.config/omarchy/plugins"],
    "maxDepth": 4,
    "maxProjects": 200,
    "openRemote": false
  },
  // Workflows reference registered actions; executable strings are rejected.
  "workflows": [{
    "id": "project.resume-configured",
    "title": "Resume Project",
    "aliases": ["resume project"],
    "parameters": [
      { "name": "project", "type": "project", "required": true }
    ],
    "steps": [
      { "action": "project.open-or-focus-editor" },
      { "action": "project.open-or-focus-terminal" }
    ],
    "stopOnFailure": true
  }],
  // Unrestricted providers require an explicit reviewed-ID allowlist.
  "providers": { "unrestricted": [] },
  // Local aggregate-only metrics; no queries, arguments, paths, or content.
  "metrics": { "enabled": true }
}
```

## Local state and privacy

| Path | Mode | Contents |
|---|---:|---|
| `~/.local/state/omnibox/usage.json` | `0600` | Stable allowlisted target/action IDs, counts, recency, pins, aliases |
| `~/.local/state/omnibox/projects.json` | `0600` | Opt-in Git project metadata and normalized credential-free remotes |
| `~/.local/state/omnibox/metrics.json` | `0600` | Numeric allowlisted counters and latency buckets only |
| `~/.cache/omnibox/packages.tsv` | `0600` | Installed package names and versions |

Parent directories are mode `0700`; writers use atomic replacement and reject
other targets. Metrics are local, inspectable, resettable, and disabled with
`\"metrics\":{\"enabled\":false}`. They never contain queries, arguments,
clipboard/file contents, paths, host names, provider output, or stdout/stderr.

See the complete [security and trust-boundary model](docs/SECURITY.md).

## Writing providers

Providers are **trusted, unsandboxed executable code**. Time, row, and byte
limits constrain resource use; they do not restrict filesystem access, network
access, or data exfiltration. Review a provider and its manifest before enabling
it.

Protocol 2 requires an executable plus a sibling `*.provider.json` manifest in:

- `<plugin dir>/providers/` for shipped providers, or
- `~/.config/omarchy/omnibox/providers/` for user providers.

A valid user manifest with the same provider `id` replaces the shipped one.
Example `notes.provider.json`:

```json
{
  "protocol": 2,
  "id": "local.notes",
  "title": "Notes",
  "executable": "notes",
  "enabled": true,
  "queryPolicy": "triggered",
  "triggers": ["note", "notes"],
  "context": [],
  "capabilities": ["query"],
  "timeoutMs": 900,
  "killAfterMs": 200,
  "maxRows": 8,
  "maxLineBytes": 16384
}
```

Triggered providers run only when the query equals a trigger or starts with
`trigger ` / `trigger:`. The executable receives the trigger-stripped query as
`$1` and a JSON object containing only manifest-allowlisted context fields as
`$2`. Clipboard and file contents are never provider context.

Providers print one compact protocol-2 JSON result per line:

```json
{"protocol":2,"id":"note:daily","type":"provider","title":"Daily note","subtitle":"~/Notes/daily.md","icon":"󰈙","value":{"path":"/home/me/Notes/daily.md"},"actions":[{"id":"note.open","title":"Open","executor":"argv","argv":["xdg-open","/home/me/Notes/daily.md"],"lifecycle":"close","risk":"safe"}]}
```

Provider actions must use an argv array. Shell action strings are rejected.
Destructive actions additionally require `"risk":"destructive"` and
`"confirm":true`. Every result is namespaced as
`provider:<provider-id>:<result-id>` and shows provider provenance in the UI.
Malformed lines reject independently; valid rows from the same or another
provider continue streaming.

`queryPolicy: "unrestricted"` is denied unless the provider ID is also listed
explicitly in user configuration:

```jsonc
{
  "providers": {
    "unrestricted": ["local.explicitly-reviewed-provider"]
  }
}
```

### Migrating a protocol-1 TSV provider

| Protocol 1 | Protocol 2 |
|---|---|
| executable file only | executable plus `*.provider.json` |
| every query passed as `$1` | manifest trigger policy; `$1` is trigger-stripped |
| `label<TAB>detail<TAB>action<TAB>icon` | one typed JSON object per line |
| opaque shell `action` | bounded `actions[]` with literal `argv[]` |
| positional/derived identity | stable provider and result IDs |
| no provenance/risk metadata | namespaced provenance, lifecycle, risk, confirmation |

There is no automatic TSV compatibility path. Keep the previous plugin release
checked out while converting a custom provider, or restore that release to roll
back.

The shipped `providers/packages` provider is triggered with `pkg` or `package`
(for example, `pkg jq`). It searches a mode-`0600` installed-package cache and
refreshes only when pacman’s local database changes.

## Product roadmap

- [Omnibox 2.0 product requirements](docs/PRODUCT_REQUIREMENTS.md)
- [Corresponding implementation TODO](docs/IMPLEMENTATION_TODO.md)
- [Security model and trust boundaries](docs/SECURITY.md)

## Testing

```bash
npm test
npm run coverage
```

`npm run coverage` uses pinned `c8@12.0.0` from npm’s external cache, so it
does not put validator-forbidden dependency symlinks inside the plugin. It
instruments every executable module in `js/` and fails if statements,
branches, functions, or lines fall below 90%. Shell helpers have focused
behavior tests; the QML IPC smoke suite runs on Omarchy and skips cleanly
elsewhere. GitHub Actions enforces the same gates on pushes and pull requests.

## Development notes

- Entry point: `Omnibox.qml` (`kind: "menu"`, `keepLoaded: true`).
- Pure-JS modules in `js/` remain Qt V4/ES5-compatible while exposing guarded
  CommonJS exports for Node coverage.
- QML edits don't hot-recompile reliably inside a running shell; use
  `omarchy restart shell` while developing.
- Window focusing uses Omarchy's Hyprland Lua dispatch
  (`hl.dsp.focus({ window = "address:0x…" })`), not the vanilla
  `focuswindow` dispatcher.

## License

MIT — see [LICENSE](LICENSE).

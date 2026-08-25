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
| **System** | Lock, suspend, logout, reboot, shutdown, screenshot, theme switcher, keybindings |
| **Clipboard** | Search your Omarchy clipboard history; Enter pastes into the focused window |
| **SSH** | Hosts from `~/.ssh/config`; Enter opens an `ssh` session in your terminal |
| **Providers** | Executable extensions that answer the query with TSV rows (see below) |

Omnibox also **learns stable targets**: frequently used apps, files, system
actions, and SSH hosts float to the top. Shell commands, provider actions,
clipboard entries, calculations, and web queries are never persisted. Usage
state is stored atomically with mode `0600`. Open the box with an empty query
to see your favorites.

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
o.bind("SUPER + SPACE", "Omnibox launcher", "omarchy-shell shell toggle ryan.omnibox")
```

Hyprland reloads bindings on save. If Super+Space still opens the stock menu
in your current session, log out and back in once — Hyprland's Lua binding
table is rebuilt at session start.

Manual summon from anywhere:

```bash
omarchy-shell shell summon ryan.omnibox '{"query":"ghost"}'
```

### Update

```bash
omarchy plugin update ryan.omnibox
```

### Remove and restore the stock launcher

First remove these two lines from `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + SPACE")
o.bind("SUPER + SPACE", "Omnibox launcher", "omarchy-shell shell toggle ryan.omnibox")
```

Then reload Hyprland and remove the plugin:

```bash
hyprctl reload
omarchy plugin remove ryan.omnibox
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
| Enter | Activate selected row |
| Alt+Enter | On file rows: open the containing folder |
| Escape | Clear query, then close |

## Prefixes

| Prefix | Meaning |
|---|---|
| `>` | Shell command (`>uname -a` → run in terminal / background) |
| `=` | Force calculator (`=42*2`) |
| none | Apps, windows, files, math auto-detect, web, everything |

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
  "maxResults": 8
}
```

## Writing providers

Providers make Omnibox a platform. Drop an executable file into either:

- `<plugin dir>/providers/` (shipped providers), or
- `~/.config/omarchy/omnibox/providers/` (your own; same basename wins)

A provider receives the query as `$1` and prints up to a handful of rows, one
per line, tab-separated:

```
label<TAB>detail<TAB>action<TAB>icon
```

- `label` — row title (required)
- `detail` — subtitle under the label (may be empty, tab required)
- `action` — shell command run on Enter (required)
- `icon` — optional Nerd Font glyph

Providers run concurrently on every debounced query. Each gets 0.9 seconds,
then a 0.2-second SIGKILL grace; output is capped to 8 rows and 16 KiB per
line. Completed providers stream into the launcher immediately, then all
provider rows are fuzzy-ranked together before `maxResults` is applied. Keep
providers fast. Minimal example:

```bash
#!/usr/bin/env bash
set -euo pipefail
q=${1:-}
[[ -n $q ]] || exit 0
printf 'Search notes for %s\tPersonal notes\tmy-notes-search %q\t󰈙\n' \"$q\" \"$q\"
```

The shipped `providers/packages` provider searches installed packages from a
mode-`0600` cache. It refreshes that cache only when pacman’s local database
changes, rather than running `pacman -Q` for every keystroke.

## Development notes

- Entry point: `Omnibox.qml` (`kind: "menu"`, `keepLoaded: true`).
- Pure-JS modules in `js/` are Qt V4/ES5-compatible; tests in `tests/` run
  under Node: `node tests/test-calc.js && node tests/test-fuzzy.js`.
- QML edits don't hot-recompile reliably inside a running shell; use
  `omarchy restart shell` while developing.
- Window focusing uses Omarchy's Hyprland Lua dispatch
  (`hl.dsp.focus({ window = "address:0x…" })`), not the vanilla
  `focuswindow` dispatcher.

## License

MIT — see [LICENSE](LICENSE).

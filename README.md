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

Omnibox also **learns**: every activation is counted, and frequently used
results float to the top. Open the box with an empty query to see your
recents/favorites.

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

Optional (recommended): route the *bare* stock-menu route into Omnibox too, so
`omarchy menu toggle` and the bar's menu button also open the launcher. Add to
`~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"root": { "action": "omarchy-shell shell toggle ryan.omnibox" }
```

Subtree routes (`system`, `capture`, `theme`, …) are unaffected.

Manual summon from anywhere:

```bash
omarchy-shell shell summon ryan.omnibox '{"query":"ghost"}'
```

### Update / remove

```bash
omarchy plugin update ryan.omnibox
omarchy plugin remove ryan.omnibox
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

Providers run on every debounced keystroke with a ~0.9s budget each, so keep
them fast. Example — the shipped `packages` provider searches installed
packages:

```bash
#!/usr/bin/env bash
set -euo pipefail
q="${1:-}"
[[ -n $q ]] || exit 0
pacman -Q 2>/dev/null | awk -v q="$q" '
  index(tolower($1), tolower(q)) {
    printf "%s\t%s · installed\txdg-terminal-exec -- bash -lc \047pacman -Qi %s; read -n 1 -s\047\t󰣇\n", $1, $2, $1
    if (++n >= 8) exit
  }'
```

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

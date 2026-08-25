import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "js/Calc.js" as Calc
import "js/Fuzzy.js" as Fuzzy

// Omnibox — an Alfred-style universal launcher for the Omarchy shell.
//
// One box for everything: apps, open windows, files, math, web search,
// clipboard history, SSH hosts, shell commands, and the Omarchy system
// actions — ranked by fuzzy match and learned usage. External providers
// (executables that answer a query with TSV rows) extend it without
// touching this file.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // ------------------------------------------------------------- lifecycle

  property bool opened: false
  property int selectedIndex: 0
  property bool cursorActive: true
  property int querySerial: 0

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.opened = true
    root.selectedIndex = 0
    root.cursorActive = true
    searchField.text = String(payload.query || "")
    searchField.cursorPosition = searchField.text.length
    root.refreshDynamicSources()
    root.rebuildDisplay()

    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    configView.reload()
    usageView.reload()
    sshView.reload()
    clipView.reload()
    root.scanProviders()
    return "ok"
  }

  function ping() { return "ok" }

  function cancel() {
    root.opened = false
    searchField.text = ""
    root.selectedIndex = 0
    if (fdProc.running) fdProc.kill()
    if (providersProc.running) providersProc.kill()
  }

  // ---------------------------------------------------------------- config
  // Optional user config at ~/.config/omarchy/extensions/omnibox.jsonc:
  //   engines   name -> search-url-with-%s (first key is the default)
  //   fileRoots directories fd searches (leading ~ expands)
  //   maxResults per-source row cap

  property var config: ({})
  readonly property var defaultConfig: ({
    "engines": {
      "DuckDuckGo": "https://duckduckgo.com/?q=%s",
      "Google": "https://www.google.com/search?q=%s",
      "YouTube": "https://www.youtube.com/results?search_query=%s",
      "GitHub": "https://github.com/search?q=%s",
      "Arch Wiki": "https://wiki.archlinux.org/index.php?search=%s"
    },
    "fileRoots": [
      "~/Documents", "~/Downloads", "~/Desktop",
      "~/Pictures", "~/Videos", "~/Music"
    ],
    "maxResults": 8
  })

  function configEngines() {
    var engines = root.config.engines
    if (engines && typeof engines === "object") return engines
    return root.defaultConfig.engines
  }

  function configFileRoots() {
    var roots = root.config.fileRoots
    if (Array.isArray(roots) && roots.length > 0) return roots
    return root.defaultConfig.fileRoots
  }

  function configMaxResults() {
    var n = Number(root.config.maxResults)
    return (isFinite(n) && n > 0) ? Math.floor(n) : 8
  }

  function stripJsonc(raw) {
    return String(raw || "")
      .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
      .replace(/,(\s*[}\]])/g, "$1")
  }

  // ----------------------------------------------------------------- usage
  // Learned ranking: ~/.local/state/omnibox/usage.json maps a stable row
  // key to {count, lastUsed, row}, where row is a snapshot that can be
  // re-shown as a favorite when the box opens empty.

  property var usage: ({})
  property string usagePath: Quickshell.env("HOME") + "/.local/state/omnibox/usage.json"

  function usageBoost(key) {
    var entry = root.usage[key]
    if (!entry) return 0
    var count = Number(entry.count) || 0
    return Math.min(18, Math.round(4 * Math.log(count + 1) / Math.LN2))
  }

  function recordUsage(row) {
    if (!row || !row.rowKey) return
    // Transient targets change meaning (window addresses, clipboard
    // indexes), so favorites only resurrect rows whose data stays true.
    var learnable = row.source !== "calc" && row.source !== "windows"
      && (row.kind === "app" || row.kind === "exec" || row.kind === "file"
      || row.kind === "copy" || row.source === "system" || row.source === "ssh"
      || row.source === "web" || row.source === "providers")
    if (!learnable) return

    var entry = root.usage[row.rowKey] || { count: 0, row: {} }
    entry.count = (Number(entry.count) || 0) + 1
    entry.lastUsed = Date.now()
    entry.row = {
      rowKey: row.rowKey,
      source: row.source,
      icon: row.icon,
      appIcon: row.appIcon,
      label: row.label,
      detail: row.detail,
      kind: row.kind,
      data: row.payload
    }
    root.usage[row.rowKey] = entry
    root.saveUsage()
  }

  function saveUsage() {
    var keys = []
    for (var k in root.usage) keys.push(k)
    if (keys.length > 400) {
      keys.sort(function(a, b) {
        return (Number(root.usage[a].lastUsed) || 0) - (Number(root.usage[b].lastUsed) || 0)
      })
      for (var i = 0; i < keys.length - 400; i++) delete root.usage[keys[i]]
    }
    usageView.setText(JSON.stringify(root.usage))
  }

  function favoriteRows() {
    var rows = []
    for (var key in root.usage) {
      var entry = root.usage[key]
      if (!entry || !entry.row || !entry.row.label) continue
      var row = root.makeRow(entry.row.source, entry.row.icon, "", entry.row.label,
        entry.row.detail || "", entry.row.kind, entry.row.data || "", entry.row.rowKey || key)
      row.appIcon = entry.row.appIcon || ""
      row.score = -(Number(entry.count) || 0)
      rows.push(row)
    }
    rows.sort(function(a, b) { return a.score - b.score })
    return rows.slice(0, root.configMaxResults() + 1)
  }

  // --------------------------------------------------------------- sources
  //
  // Each source turns the current query into candidate rows. Static and
  // in-memory sources run synchronously; fd and external providers run as
  // debounced subprocesses and merge their rows in when they land.

  property var windows: []
  property var sshHosts: []
  property var clipEntries: []
  property var providerList: []        // [{name, path}]
  property var fileRows: []            // last fd batch (absolute paths)
  property var providerRows: ({})      // provider name -> parsed rows
  property var appIconIndex: ({})      // normalized desktop id -> icon source

  readonly property var systemRows: [
    { id: "lock", icon: "󰌾", label: "Lock", aliases: "lock screen secure", action: "omarchy-system-lock" },
    { id: "clipboard", icon: "", label: "Clipboard", aliases: "paste history clipboard manager", action: "omarchy-shell shell toggle omarchy.clipboard" },
    { id: "emoji", icon: "", label: "Emoji", aliases: "emoji symbols emoticon", action: "omarchy-shell shell toggle omarchy.emojis" },
    { id: "theme", icon: "󰸌", label: "Theme", aliases: "themes appearance style", action: "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\"" },
    { id: "menu", icon: "󰣇", label: "Omarchy Menu", aliases: "omarchy menu settings preferences configure setup", action: "omarchy-menu toggle setup" },
    { id: "keybindings", icon: "󰌌", label: "Keybindings", aliases: "shortcuts keys help", action: "omarchy-menu-keybindings" },
    { id: "screenshot", icon: "󰆧", label: "Screenshot", aliases: "capture screenshot snap", action: "omarchy-capture-screenshot" },
    { id: "suspend", icon: "󰒲", label: "Suspend", aliases: "sleep suspend", action: "systemctl suspend" },
    { id: "logout", icon: "󰍃", label: "Log Out", aliases: "logout sign out log off", action: "omarchy-system-logout" },
    { id: "reboot", icon: "󰜉", label: "Reboot", aliases: "restart reboot", action: "omarchy-system-reboot" },
    { id: "shutdown", icon: "󰐥", label: "Shutdown", aliases: "shutdown power off turn off", action: "omarchy-system-shutdown" }
  ]

  function makeRow(source, icon, appIcon, label, detail, kind, data, rowKey) {
    return {
      source: source,
      icon: icon,
      iconFont: "",
      appIcon: appIcon,
      label: label,
      detail: detail,
      kind: kind,
      data: data,
      rowKey: rowKey,
      score: 0
    }
  }

  function searchTextFor(query) {
    return Fuzzy.normalize(query)
  }

  // -- apps ---------------------------------------------------------------

  function rebuildAppIconIndex() {
    var index = ({})
    if (!root.appLibrary) return index
    var entries = root.appLibrary.sortedEntries("")
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var base = appId.toLowerCase().replace(/\.desktop$/, "")
      index[base] = root.appLibrary.iconSource(String(entry.icon || ""))
    }
    return index
  }

  function appRows(query) {
    var rows = []
    if (!root.appLibrary) return rows
    var entries = root.appLibrary.sortedEntries("")
    var max = root.configMaxResults()
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var name = root.appLibrary.entryName(entry)
      var subtext = root.appLibrary.entrySubtext(entry)
      var haystack = name
      if (subtext) haystack += " " + subtext
      try {
        if (entry.keywords && typeof entry.keywords.join === "function")
          haystack += " " + entry.keywords.join(" ")
      } catch (e) { }
      var score = Fuzzy.score(query, haystack)
      if (score === null) continue
      var row = root.makeRow("apps", "", root.appLibrary.iconSource(String(entry.icon || "")),
        name, subtext || "", "app", appId, "app:" + appId)
      row.score = score - root.usageBoost(row.rowKey)
      rows.push(row)
      if (rows.length >= max * 3) break
    }
    rows.sort(function(a, b) { return a.score - b.score })
    return rows.slice(0, max)
  }

  // -- windows ------------------------------------------------------------

  function windowRows(query) {
    var rows = []
    var max = root.configMaxResults()
    for (var i = 0; i < root.windows.length; i++) {
      var win = root.windows[i]
      var title = String(win.title || "")
      var klass = String(win.class || "")
      var haystack = (title + " " + klass).trim()
      if (!haystack) continue
      var score = query ? Fuzzy.score(query, haystack) : i
      if (query && score === null) continue
      var label = title || klass
      var ws = win.workspace ? String(win.workspace.name || win.workspace.id || "") : ""
      var detail = klass && title ? klass + " · " + ws : ws
      var row = root.makeRow("windows", "󰍲", "", label, detail,
        "window", String(win.address || ""), "win:" + String(win.address || ""))
      row.score = (score || 0) + 2
      rows.push(row)
      if (rows.length >= max) break
    }
    return rows
  }

  function refreshWindows() {
    windowsProc.command = ["hyprctl", "-j", "clients"]
    windowsProc.collected = ""
    if (windowsProc.running) windowsProc.kill()
    windowsProc.running = true
  }

  // -- files --------------------------------------------------------------

  function homePath(path) {
    var p = String(path || "")
    if (p === "~") return Quickshell.env("HOME")
    if (p.indexOf("~/") === 0) return Quickshell.env("HOME") + p.slice(1)
    return p
  }

  function shortPath(path) {
    var home = Quickshell.env("HOME")
    var p = String(path || "")
    if (p === home) return "~"
    if (p.indexOf(home + "/") === 0) return "~" + p.slice(home.length)
    return p
  }

  function fileIcon(path, isDir) {
    if (isDir) return "󰉋"
    var name = String(path || "").toLowerCase()
    var dot = name.lastIndexOf(".")
    var ext = dot >= 0 ? name.slice(dot + 1) : ""
    if (ext === "png" || ext === "jpg" || ext === "jpeg" || ext === "gif" || ext === "webp" || ext === "svg" || ext === "heic") return "󰋩"
    if (ext === "mp4" || ext === "mkv" || ext === "webm" || ext === "mov" || ext === "avi") return "󰕧"
    if (ext === "mp3" || ext === "flac" || ext === "ogg" || ext === "wav" || ext === "m4a" || ext === "opus") return "󰝚"
    if (ext === "pdf" || ext === "epub") return "󰈦"
    if (ext === "zip" || ext === "tar" || ext === "gz" || ext === "xz" || ext === "zst" || ext === "7z" || ext === "rar") return "󰗄"
    if (ext === "md" || ext === "txt" || ext === "doc" || ext === "docx" || ext === "odt") return "󰈙"
    if (ext === "js" || ext === "ts" || ext === "py" || ext === "rb" || ext === "go" || ext === "rs" || ext === "c" || ext === "h" || ext === "cpp" || ext === "lua" || ext === "sh" || ext === "json" || ext === "toml" || ext === "yaml" || ext === "yml" || ext === "qml") return "󰅩"
    return "󰈗"
  }

  function fileRowsFromBatch(query) {
    var rows = []
    var max = root.configMaxResults()
    for (var i = 0; i < root.fileRows.length; i++) {
      var raw = root.fileRows[i]
      var isDir = raw.charAt(raw.length - 1) === "/"
      var path = isDir ? raw.slice(0, -1) : raw
      var slash = path.lastIndexOf("/")
      var base = slash >= 0 ? path.slice(slash + 1) : path
      var dir = slash > 0 ? path.slice(0, slash) : "/"
      var row = root.makeRow("files", root.fileIcon(base, isDir), "",
        base, root.shortPath(dir), "file", path, "file:" + raw)
      row.score = 28 + i * 2 - root.usageBoost(row.rowKey)
      rows.push(row)
      if (rows.length >= max) break
    }
    return rows
  }

  function runFileSearch(query) {
    if (!query) {
      root.fileRows = []
      return
    }
    var pattern = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    var roots = root.configFileRoots()
    var quotedRoots = ""
    for (var i = 0; i < roots.length; i++) {
      var p = root.homePath(roots[i])
      if (p) quotedRoots += " " + Util.shellQuote(p)
    }
    var script = "command -v fd >/dev/null 2>&1 || exit 0; "
      + "timeout 1.2 fd -d 8 -E .git -E node_modules -E .cache -E Trash "
      + "-t f -t d -t l --color never -- " + Util.shellQuote(pattern) + quotedRoots
      + " 2>/dev/null | head -n 30"
    fdProc.querySerial = root.querySerial
    fdProc.collected = ""
    if (fdProc.running) fdProc.kill()
    fdProc.command = ["bash", "-lc", script]
    fdProc.running = true
  }

  // -- calculator ----------------------------------------------------------

  function calcRows(query) {
    if (!Calc.looksLikeMath(query)) return []
    var result = Calc.evaluate(query)
    if (!result || !result.ok) return []
    var row = root.makeRow("calc", "󰃬", "", "= " + result.display,
      "Copy result", "copy", String(result.display), "calc")
    row.score = -100
    return [row]
  }

  // -- web -----------------------------------------------------------------

  function looksLikeUrl(query) {
    var q = String(query || "").trim()
    if (!q || q.indexOf(" ") >= 0) return ""
    if (/^(https?|ftp):\/\/\S+$/i.test(q)) return q
    if (/^www\.\S+$/i.test(q)) return "https://" + q
    if (/^[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)+(:\d+)?(\/\S*)?$/i.test(q)) return "https://" + q
    return ""
  }

  function webRows(query) {
    var rows = []
    var q = String(query || "").trim()
    if (q.length < 2) return rows

    var url = root.looksLikeUrl(q)
    if (url) {
      var row = root.makeRow("web", "󰖟", "", "Open " + url.replace(/^https:\/\//, ""),
        "Open in browser", "exec", "xdg-open " + Util.shellQuote(url), "url:" + url)
      row.score = -20
      rows.push(row)
    }

    var engines = root.configEngines()
    var first = true
    for (var name in engines) {
      var template = String(engines[name] || "")
      if (!template) continue
      var target = template.split("%s").join(encodeURIComponent(q))
      var searchRow = root.makeRow("web", "󰈉", "",
        "Search " + name + " for “" + q + "”", "",
        "exec", "xdg-open " + Util.shellQuote(target), "web:" + name)
      searchRow.score = (first ? 130 : 150) - root.usageBoost(searchRow.rowKey)
      rows.push(searchRow)
      first = false
    }
    return rows
  }

  // -- shell commands --------------------------------------------------------

  function runRows(query) {
    var cmd = String(query || "").slice(1).trim()
    if (!cmd) return []
    var terminal = "xdg-terminal-exec -- bash -lc " + Util.shellQuote(cmd)
    var rows = [
      root.makeRow("run", "", "", "Run in terminal: " + cmd, "", "exec", terminal, "run:t:" + cmd),
      root.makeRow("run", "󰧑", "", "Run in background: " + cmd, "", "exec", cmd, "run:b:" + cmd)
    ]
    rows[0].score = 0 - root.usageBoost(rows[0].rowKey)
    rows[1].score = 1 - root.usageBoost(rows[1].rowKey)
    return rows
  }

  // -- system ----------------------------------------------------------------

  function systemRowList(query) {
    var rows = []
    for (var i = 0; i < root.systemRows.length; i++) {
      var spec = root.systemRows[i]
      var score = query ? Fuzzy.score(query, spec.label + " " + spec.aliases) : 100 + i
      if (query && score === null) continue
      var row = root.makeRow("system", spec.icon, "", spec.label, "",
        "exec", spec.action, "sys:" + spec.id)
      row.score = (score || 0) + 8 - root.usageBoost(row.rowKey)
      rows.push(row)
    }
    return rows
  }

  // -- ssh --------------------------------------------------------------------

  function sshRows(query) {
    var rows = []
    var max = root.configMaxResults()
    for (var i = 0; i < root.sshHosts.length; i++) {
      var host = root.sshHosts[i]
      var score = Fuzzy.score(query, host)
      if (score === null) continue
      var row = root.makeRow("ssh", "󰣀", "", "SSH " + host, "Open terminal session",
        "exec", "xdg-terminal-exec -- ssh " + Util.shellQuote(host), "ssh:" + host)
      row.score = score + 4 - root.usageBoost(row.rowKey)
      rows.push(row)
      if (rows.length >= max) break
    }
    return rows
  }

  // -- clipboard ----------------------------------------------------------------

  function clipboardRows(query) {
    var rows = []
    var max = root.configMaxResults()
    for (var i = 0; i < root.clipEntries.length; i++) {
      var entry = root.clipEntries[i]
      var score = Fuzzy.score(query, entry.searchText)
      if (score === null) continue
      var row
      if (entry.type === "image") {
        row = root.makeRow("clipboard", "󰋩", "", entry.label, "Image — copy again",
          "exec", root.omarchyPath + "/bin/omarchy-clipboard-paste-file --copy-only "
            + Util.shellQuote(entry.mime) + " " + Util.shellQuote(entry.data),
          "clip:" + i)
      } else {
        row = root.makeRow("clipboard", "", "", entry.label, "Paste",
          "clipboard", String(entry.index), "clip:" + i)
      }
      row.score = score + 6
      rows.push(row)
      if (rows.length >= max) break
    }
    return rows
  }

  // -- external providers ---------------------------------------------------------
  //
  // Executables in <plugin>/providers/ and ~/.config/omarchy/omnibox/providers/
  // receive the query as $1 and print TSV rows: label\tdetail\taction[\ticon].
  // A single bash pass runs them all with a per-provider timeout and prefixes
  // each line with the provider name.

  property string userProvidersDir: Quickshell.env("HOME") + "/.config/omarchy/omnibox/providers"

  function pluginProvidersDir() {
    var manifest = root.manifest
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir) + "/providers"
    return Quickshell.env("HOME") + "/.config/omarchy/plugins/ryan.omnibox/providers"
  }

  function scanProviders() {
    scanProc.collected = ""
    scanProc.command = ["bash", "-lc",
      "for dir in " + Util.shellQuote(root.pluginProvidersDir()) + " " + Util.shellQuote(root.userProvidersDir) + "; do "
      + "[[ -d $dir ]] || continue; "
      + "for f in \"$dir\"/*; do [[ -f $f && -x $f ]] || continue; printf '%s\\t%s\\n' \"${f##*/}\" \"$f\"; done; "
      + "done"]
    scanProc.running = true
  }

  function runProviders(query) {
    if (!query || root.providerList.length === 0) {
      root.providerRows = ({})
      return
    }
    var script = "q=" + Util.shellQuote(query) + "; "
    for (var i = 0; i < root.providerList.length; i++) {
      var provider = root.providerList[i]
      script += "timeout 0.9 " + Util.shellQuote(provider.path) + " \"$q\" 2>/dev/null | head -n 8 "
        + "| while IFS= read -r line; do [[ -n $line ]] && printf '%s\\t%s\\n' "
        + Util.shellQuote(provider.name) + " \"$line\"; done; "
    }
    providersProc.querySerial = root.querySerial
    providersProc.collected = ""
    if (providersProc.running) providersProc.kill()
    providersProc.command = ["bash", "-lc", script]
    providersProc.running = true
  }

  function providerRowList(query) {
    var rows = []
    var max = root.configMaxResults()
    for (var i = 0; i < root.providerList.length; i++) {
      var name = root.providerList[i].name
      var batch = root.providerRows[name]
      if (!batch) continue
      for (var j = 0; j < batch.length && rows.length < max; j++) {
        var parsed = batch[j]
        var row = root.makeRow("providers", parsed.icon || "󰐢", "", parsed.label,
          parsed.detail || name, "exec", parsed.action, "prov:" + name + ":" + parsed.label)
        row.score = 60 + j * 2 - root.usageBoost(row.rowKey)
        rows.push(row)
      }
    }
    return rows
  }

  // ------------------------------------------------------------- display

  ListModel { id: displayModel }

  readonly property var sourceOrder: ["calc", "apps", "windows", "files", "clipboard", "system", "web", "ssh", "run", "providers"]
  readonly property var sourceLabels: ({
    calc: "", apps: "Apps", windows: "Windows", files: "Files",
    clipboard: "Clipboard", system: "System", web: "Web", ssh: "SSH",
    run: "Run", providers: "More"
  })

  function currentQuery() {
    return searchField.text.trim()
  }

  function rebuildDisplay() {
    displayModel.clear()

    var query = root.currentQuery()
    var rows = []

    if (!query) {
      rows = root.favoriteRows()
      if (rows.length === 0) rows = root.systemRowList("")
      for (var f = 0; f < rows.length; f++) rows[f].score = f
    } else if (query.charAt(0) === ">") {
      rows = root.runRows(query)
    } else {
      var buckets = {
        calc: root.calcRows(query),
        apps: root.appRows(query),
        windows: root.windowRows(query),
        files: root.fileRowsFromBatch(query),
        clipboard: root.clipboardRows(query),
        system: root.systemRowList(query),
        web: root.webRows(query),
        ssh: query.length >= 2 ? root.sshRows(query) : [],
        run: [],
        providers: root.providerRowList(query)
      }
      var byScore = function(a, b) {
        if (a.score !== b.score) return a.score - b.score
        return String(a.label).localeCompare(String(b.label))
      }
      for (var bi = 0; bi < root.sourceOrder.length; bi++) {
        var bucket = buckets[root.sourceOrder[bi]] || []
        bucket.sort(byScore)
        for (var bj = 0; bj < bucket.length; bj++) rows.push(bucket[bj])
      }
    }

    // Section captions only when a search mixes several sources.
    var sections = ({})
    for (var s = 0; s < rows.length; s++) sections[rows[s].source] = true
    var sectionCount = 0
    for (var src in sections) sectionCount++
    var showSections = query && sectionCount > 1

    var lastSource = ""
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var section = ""
      if (showSections && row.source !== lastSource) {
        section = root.sourceLabels[row.source] || row.source
        if (row.source === "providers") section = "Providers"
      }
      lastSource = row.source
      displayModel.append({
        rowKey: row.rowKey,
        source: row.source,
        icon: row.icon,
        iconFont: row.iconFont || "",
        appIcon: row.appIcon || "",
        label: row.label,
        detail: row.detail || "",
        kind: row.kind,
        payload: row.data,
        section: section
      })
    }

    layoutSerial += 1
    if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  function onQueryChanged() {
    root.querySerial += 1
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay()
    searchTimer.restart()
  }

  function refreshDynamicSources() {
    root.appIconIndex = root.rebuildAppIconIndex()
    root.refreshWindows()
    var query = root.currentQuery()
    if (query && query.charAt(0) !== ">") {
      root.runFileSearch(query)
      root.runProviders(query)
    }
  }

  // ------------------------------------------------------------ activation

  function hintFor(index) {
    if (index < 0 || index >= displayModel.count) return ""
    var row = displayModel.get(index)
    if (row.kind === "app") return "Open"
    if (row.kind === "window") return "Focus"
    if (row.kind === "file") return "Open · Alt+Enter reveals"
    if (row.kind === "copy") return "Enter copies"
    if (row.kind === "clipboard") return "Paste"
    if (row.kind === "exec") return "Run"
    return ""
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.cursorActive = true
    root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    root.revealCursor()
  }

  function revealCursor() {
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activateIndex(index, modifiers) {
    if (index < 0 || index >= displayModel.count) return
    // Snapshot the fields immediately: clearing the query below rebuilds the
    // model, which invalidates objects returned by ListModel.get().
    var modelRow = displayModel.get(index)
    var row = {
      rowKey: modelRow.rowKey,
      source: modelRow.source,
      icon: modelRow.icon,
      appIcon: modelRow.appIcon,
      label: modelRow.label,
      detail: modelRow.detail,
      kind: modelRow.kind,
      payload: modelRow.payload
    }
    var alt = !!(modifiers & Qt.AltModifier)

    root.recordUsage(row)
    root.opened = false
    searchField.text = ""
    root.selectedIndex = 0

    if (row.kind === "app") {
      if (root.appLibrary) root.appLibrary.launch(row.payload, row.label)
      return
    }
    if (row.kind === "window") {
      // Omarchy's Hyprland builds dispatch through a Lua shim; the plain
      // `focuswindow` dispatcher is not exposed. hl.dsp.focus accepts a
      // window by "address:0x..." string.
      Util.execDetached("hyprctl dispatch " + Util.shellQuote('hl.dsp.focus({ window = "address:' + row.payload + '" })'))
      return
    }
    if (row.kind === "file") {
      var target = row.payload
      if (alt) {
        var slash = String(target).lastIndexOf("/")
        if (slash > 0) target = target.slice(0, slash)
      }
      Util.execDetached("xdg-open " + Util.shellQuote(target))
      return
    }
    if (row.kind === "copy") {
      Util.execDetached("printf %s " + Util.shellQuote(row.payload) + " | wl-copy")
      Util.execDetached("omarchy-notification-send -g 󰆏 " + Util.shellQuote("Copied " + row.payload))
      return
    }
    if (row.kind === "clipboard") {
      Util.execDetached(root.omarchyPath + "/bin/omarchy-clipboard-paste-text --shift-insert --history-index " + row.payload)
      return
    }
    if (row.payload) Util.execDetached(row.payload)
  }

  function activateCurrent(modifiers) {
    if (displayModel.count === 0) return
    root.activateIndex(root.cursorActive ? root.selectedIndex : 0, modifiers || Qt.NoModifier)
  }

  // ------------------------------------------------------------ processes

  Process {
    id: windowsProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { windowsProc.collected += data + "\n" }
    }
    onExited: {
      try {
        var clients = JSON.parse(windowsProc.collected || "[]")
        var visible = []
        for (var i = 0; i < clients.length; i++) {
          var c = clients[i]
          if (!c || !c.address) continue
          visible.push(c)
        }
        visible.sort(function(a, b) {
          return (Number(a.focusHistoryID) || 0) - (Number(b.focusHistoryID) || 0)
        })
        root.windows = visible
      } catch (e) {
        root.windows = []
      }
      if (root.opened) root.rebuildDisplay()
    }
  }

  Process {
    id: fdProc
    property int querySerial: 0
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { fdProc.collected += data + "\n" }
    }
    onExited: {
      if (fdProc.querySerial !== root.querySerial) return
      var lines = fdProc.collected.split("\n")
      var paths = []
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (line) paths.push(line)
      }
      root.fileRows = paths
      if (root.opened) root.rebuildDisplay()
    }
  }

  Process {
    id: providersProc
    property int querySerial: 0
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { providersProc.collected += data + "\n" }
    }
    onExited: {
      if (providersProc.querySerial !== root.querySerial) return
      var next = ({})
      var lines = providersProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var parts = line.split("\t")
        if (parts.length < 4) continue
        var name = parts[0]
        var label = parts[1]
        var detail = parts[2]
        var action = parts[3]
        var icon = parts.length > 4 ? parts[4] : ""
        if (!label || !action) continue
        if (!next[name]) next[name] = []
        next[name].push({ label: label, detail: detail, action: action, icon: icon })
      }
      root.providerRows = next
      if (root.opened) root.rebuildDisplay()
    }
  }

  Process {
    id: scanProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { scanProc.collected += data + "\n" }
    }
    onExited: {
      // User providers win over shipped ones with the same name, so the
      // shipped set is loaded first and overwritten below.
      var byName = ({})
      var order = []
      var lines = scanProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var tab = line.indexOf("\t")
        if (tab <= 0) continue
        var name = line.slice(0, tab)
        var path = line.slice(tab + 1)
        if (!byName[name]) order.push(name)
        byName[name] = path
      }
      var list = []
      for (var j = 0; j < order.length; j++)
        list.push({ name: order[j], path: byName[order[j]] })
      root.providerList = list
      if (root.opened) root.runProviders(root.currentQuery())
    }
  }

  Timer {
    id: searchTimer
    interval: 130
    onTriggered: {
      var query = root.currentQuery()
      if (!query || query.charAt(0) === ">") {
        root.fileRows = []
        root.providerRows = ({})
        return
      }
      root.runFileSearch(query)
      root.runProviders(query)
    }
  }

  // -------------------------------------------------------------- watchers

  FileView {
    id: configView
    path: Quickshell.env("HOME") + "/.config/omarchy/extensions/omnibox.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(root.stripJsonc(text()))
        root.config = (parsed && typeof parsed === "object") ? parsed : ({})
      } catch (e) { root.config = ({}) }
      if (root.opened) root.rebuildDisplay()
    }
    onLoadFailed: { root.config = ({}) }
    onFileChanged: reload()
  }

  FileView {
    id: usageView
    path: root.usagePath
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.usage = (parsed && typeof parsed === "object") ? parsed : ({})
      } catch (e) { root.usage = ({}) }
    }
  }

  FileView {
    id: sshView
    path: Quickshell.env("HOME") + "/.ssh/config"
    watchChanges: true
    printErrors: false
    onLoaded: { root.parseSshConfig(text()) }
    onLoadFailed: { root.sshHosts = [] }
    onFileChanged: reload()
  }

  function parseSshConfig(raw) {
    var hosts = []
    var seen = ({})
    var inMatch = false
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/#.*$/, "").trim()
      if (!line) continue
      var lower = line.toLowerCase()
      if (lower.indexOf("match ") === 0 || lower === "match") { inMatch = true; continue }
      if (lower.indexOf("host ") === 0) {
        inMatch = false
        var names = line.slice(5).trim().split(/\s+/)
        for (var j = 0; j < names.length; j++) {
          var host = names[j]
          if (!host || host.indexOf("*") >= 0 || host.indexOf("?") >= 0) continue
          if (seen[host]) continue
          seen[host] = true
          hosts.push(host)
        }
      }
    }
    root.sshHosts = hosts
  }

  FileView {
    id: clipView
    path: Quickshell.env("HOME") + "/.local/state/omarchy/clipboard-history.json"
    watchChanges: true
    printErrors: false
    onLoaded: { root.parseClipboard(text()) }
    onLoadFailed: { root.clipEntries = [] }
    onFileChanged: reload()
  }

  function parseClipboard(raw) {
    var entries = []
    try {
      var history = JSON.parse(String(raw || "[]"))
      if (!Array.isArray(history)) history = []
      for (var i = 0; i < history.length; i++) {
        var item = history[i]
        if (!item) continue
        if (item.type === "text") {
          var text = String(item.text || "").replace(/\s+/g, " ").trim()
          if (!text) continue
          entries.push({
            index: i,
            type: "text",
            searchText: text,
            label: text.length > 90 ? text.slice(0, 90) + "…" : text,
            mime: "",
            data: ""
          })
        } else if (item.type === "image") {
          var path = String(item.path || "")
          if (!path) continue
          var base = path.slice(path.lastIndexOf("/") + 1)
          entries.push({
            index: i,
            type: "image",
            searchText: base,
            label: "Image · " + base,
            mime: String(item.mime || "image/png"),
            data: path
          })
        }
      }
    } catch (e) { entries = [] }
    root.clipEntries = entries
    if (root.opened && root.currentQuery()) root.rebuildDisplay()
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      root.appIconIndex = root.rebuildAppIconIndex()
      if (root.opened) root.rebuildDisplay()
    }
  }

  Component.onCompleted: {
    root.scanProviders()
    root.refreshWindows()
  }

  // -------------------------------------------------------------------- ui

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  property int contentMargin: Style.spacing.panelPadding
  property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int rowSpacing: Style.spacing.xs
  property int inputHeight: Style.space(56)
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  property int layoutSerial: 0

  property int cardWidth: Style.space(460)
  readonly property int cardTop: Math.round(panel.height * 0.22)

  function rowHeightFor(row) {
    return row.detail ? root.detailRowHeight : root.baseRowHeight
  }

  function availableRowsHeight() {
    var available = panel.height - root.cardTop - Style.gapsOut - root.contentMargin * 2
      - root.inputHeight - root.contentSpacing()
    return Math.max(root.baseRowHeight, Math.min(available, Math.round(panel.height * 0.6)))
  }

  function contentSpacing() { return Style.spacing.md }

  function rowsHeight(_serial) {
    if (displayModel.count === 0) return root.baseRowHeight
    var totals = []
    var total = 0
    var available = root.availableRowsHeight()
    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (i > 0) total += root.rowSpacing
      if (row.section) total += Style.space(22)
      total += root.rowHeightFor(row)
      totals.push(total)
    }
    var count = totals.length
    if (totals[count - 1] <= available) return totals[count - 1]

    var full = 0
    while (full < count && totals[full] <= available) full++
    while (full > 1 && totals[full - 1] + root.rowSpacing + root.rowPeek > available) full--
    if (full < 1) return Math.max(available, root.baseRowHeight)
    return totals[full - 1] + root.rowSpacing + root.rowPeek
  }

  property int cardHeight: root.contentMargin * 2 + root.inputHeight + root.contentSpacing() + root.rowsHeight(layoutSerial)

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "ryan-omnibox"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(root.cardHeight, panel.height - Style.gapsOut - root.cardTop)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.cardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing()

        Row {
          width: parent.width
          height: root.inputHeight
          spacing: Style.space(10)

          Text {
            text: "󰈉"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          TextField {
            id: searchField
            width: parent.width - Style.space(10) - Style.font.iconLarge - hintText.width - Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Apps, files, math, web…"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: root.foreground
            selectionColor: Util.alpha(root.foreground, 0.3)
            selectedTextColor: root.foreground
            placeholderTextColor: Util.alpha(root.foreground, 0.4)
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            background: Rectangle { color: "transparent" }
            onTextChanged: root.onQueryChanged()

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (searchField.text) searchField.text = ""
                else root.cancel()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.select(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.select(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_PageDown) {
                root.select(6)
                event.accepted = true
              } else if (event.key === Qt.Key_PageUp) {
                root.select(-6)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activateCurrent(event.modifiers)
                event.accepted = true
              }
            }
          }

          Text {
            id: hintText
            text: root.hintFor(root.cursorActive ? root.selectedIndex : -1)
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Item {
          width: parent.width
          height: root.rowsHeight(layoutSerial)

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds

            section.property: "section"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section
              width: ListView.view.width
              height: Style.space(22)
              visible: section !== ""

              Text {
                text: section.toUpperCase()
                color: root.foreground
                opacity: 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.DemiBold
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            delegate: BorderSurface {
              id: row
              required property int index
              required property string rowKey
              required property string source
              required property string icon
              required property string iconFont
              required property string appIcon
              required property string label
              required property string detail
              required property string kind
              required property string payload

              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeightFor(row)
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Text {
                id: iconText
                visible: row.icon.length > 0 && !row.appIcon
                text: row.icon
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: row.iconFont.length > 0 ? row.iconFont : root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Image {
                id: appIconImage
                visible: row.appIcon.length > 0
                width: Style.font.iconLarge
                height: Style.font.iconLarge
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: row.appIcon
                asynchronous: true
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8) + (Style.space(36) - width) / 2
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.left: (row.icon.length > 0 || row.appIcon.length > 0)
                  ? parent.left : parent.left
                anchors.leftMargin: (row.icon.length > 0 || row.appIcon.length > 0)
                  ? Style.space(52) : Style.space(14)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(14)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: row.label
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: row.detail
                  visible: row.detail.length > 0
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.selectedIndex = row.index }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activateIndex(row.index, Qt.NoModifier)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0 && root.currentQuery()

            Text {
              text: "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }

            Text {
              text: "No matches for “" + root.currentQuery() + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }
          }
        }
      }
    }
  }
}

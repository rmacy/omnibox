import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "js/Calc.js" as Calc
import "js/Fuzzy.js" as Fuzzy
import "js/Jsonc.js" as Jsonc

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
    root.rebuildDisplay(false)

    var query = root.currentQuery()
    if (query && query.charAt(0) !== ">") searchTimer.restart()
    else searchTimer.stop()

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

  function stopAsyncSearch() {
    fdProc.latestRun += 1
    fdProc.pending = false
    fdProc.pendingCommand = []
    providersProc.latestRun += 1
    providersProc.pending = false
    providersProc.pendingCommand = []
    providerPublishTimer.stop()
    fdProc.running = false
    providersProc.running = false
  }

  function cancel() {
    root.opened = false
    var hadQuery = searchField.text.length > 0
    searchField.text = ""
    root.selectedIndex = 0
    searchTimer.stop()
    if (!hadQuery) {
      root.querySerial += 1
      root.fileRows = []
      root.providerRows = ({})
      root.stopAsyncSearch()
    }
  }

  // ---------------------------------------------------------------- config
  // Optional user config at ~/.config/omarchy/extensions/omnibox.jsonc:
  //   engines   name -> search-url-with-%s (first key is the default)
  //   fileRoots directories fd searches (leading ~ expands)
  //   maxResults per-source row cap

  property var config: ({})
  property string configError: ""
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

  function applyConfig(value) {
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new Error("Config root must be an object")
    root.config = value
    root.configError = ""
    root.querySerial += 1
    root.fileRows = []
    root.providerRows = ({})
    root.stopAsyncSearch()
    if (!root.opened) return
    root.rebuildDisplay()
    var query = root.currentQuery()
    if (query && query.charAt(0) !== ">") searchTimer.restart()
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

  function isLearnableUsageRow(row) {
    if (!row) return false
    if (row.source === "apps") return row.kind === "app"
    if (row.source === "files") return row.kind === "file"
    if (row.source === "system" || row.source === "ssh") return row.kind === "exec"
    return false
  }

  function systemSpec(id) {
    for (var i = 0; i < root.systemRows.length; i++)
      if (root.systemRows[i].id === id) return root.systemRows[i]
    return null
  }

  function isSafeSshHost(host) {
    return /^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(String(host || ""))
  }

  function usageIdentity(row, fallbackKey) {
    var key = String((row && row.rowKey) || fallbackKey || "")
    if (!row) return ""
    if (row.source === "apps") return String(row.payload !== undefined ? row.payload : row.data || "")
    if (row.source === "files") {
      var path = String(row.payload !== undefined ? row.payload : row.data || "")
      return path.charAt(0) === "/" ? path : ""
    }
    if (row.source === "system") {
      var systemId = key.indexOf("sys:") === 0 ? key.slice(4) : ""
      return root.systemSpec(systemId) ? systemId : ""
    }
    if (row.source === "ssh") {
      var host = key.indexOf("ssh:") === 0 ? key.slice(4) : ""
      return root.isSafeSshHost(host) ? host : ""
    }
    return ""
  }

  function usageKey(source, identity) {
    if (source === "apps") return "app:" + identity
    if (source === "files") return "file:" + identity
    if (source === "system") return "sys:" + identity
    if (source === "ssh") return "ssh:" + identity
    return ""
  }

  function sanitizeUsage(value) {
    var next = ({})
    if (!value || typeof value !== "object") return next
    for (var key in value) {
      var entry = value[key]
      var row = entry && entry.row
      if (!entry || !row || !root.isLearnableUsageRow(row)) continue
      var source = String(row.source || "")
      var identity = root.usageIdentity(row, key)
      var canonicalKey = root.usageKey(source, identity)
      if (!identity || !canonicalKey) continue
      var count = Number(entry.count)
      var lastUsed = Number(entry.lastUsed)
      next[canonicalKey] = {
        count: isFinite(count) && count > 0 ? count : 1,
        lastUsed: isFinite(lastUsed) && lastUsed > 0 ? lastUsed : 0,
        row: {
          rowKey: canonicalKey,
          source: source,
          icon: String(row.icon || ""),
          appIcon: String(row.appIcon || ""),
          label: String(row.label || ""),
          detail: String(row.detail || ""),
          kind: source === "apps" ? "app" : (source === "files" ? "file" : "exec"),
          data: identity
        }
      }
    }
    return next
  }

  function loadUsage(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      root.usage = root.sanitizeUsage(parsed)
      // Rewrites legacy state atomically, removes executable history, and
      // migrates the directory/file to 0700/0600.
      root.saveUsage()
    } catch (e) {
      root.usage = ({})
      console.warn("omnibox: refusing to overwrite invalid usage state:", e)
    }
  }

  function recordUsage(row) {
    if (!row || !row.rowKey || !root.isLearnableUsageRow(row)) return
    var identity = root.usageIdentity(row, row.rowKey)
    var canonicalKey = root.usageKey(row.source, identity)
    if (!identity || !canonicalKey) return

    var entry = root.usage[canonicalKey] || { count: 0, row: {} }
    entry.count = (Number(entry.count) || 0) + 1
    entry.lastUsed = Date.now()
    entry.row = {
      rowKey: canonicalKey,
      source: row.source,
      icon: row.icon,
      appIcon: row.appIcon,
      label: row.label,
      detail: row.detail,
      kind: row.source === "apps" ? "app" : (row.source === "files" ? "file" : "exec"),
      data: identity
    }
    root.usage[canonicalKey] = entry
    root.saveUsage()
  }

  function pluginSourceDir() {
    return root.manifest && root.manifest.__sourceDir
      ? String(root.manifest.__sourceDir)
      : Quickshell.env("HOME") + "/.config/omarchy/plugins/ryan.omnibox"
  }

  function usageWriterPath() {
    return root.pluginSourceDir() + "/bin/write-usage"
  }

  function fileSearchPath() {
    return root.pluginSourceDir() + "/bin/search-files"
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
    root.queueUsageWrite(JSON.stringify(root.usage))
  }

  function queueUsageWrite(payload) {
    usageWriterProc.pendingPayload = String(payload || "{}")
    usageWriterProc.pending = true
    if (!usageWriterProc.running) root.startUsageWrite()
  }

  function startUsageWrite() {
    if (!usageWriterProc.pending || usageWriterProc.running) return
    usageWriterProc.activePayload = usageWriterProc.pendingPayload
    usageWriterProc.pending = false
    usageWriterProc.command = [root.usageWriterPath(), root.usagePath]
    usageWriterProc.running = true
  }

  function restoreUsageRow(entry, key) {
    var saved = entry && entry.row
    if (!saved) return null
    var source = String(saved.source || "")
    var identity = String(saved.data || "")
    var canonicalKey = root.usageKey(source, identity)
    if (!identity || !canonicalKey || canonicalKey !== key) return null

    var row
    if (source === "apps") {
      row = root.makeRow("apps", String(saved.icon || ""), String(saved.appIcon || ""),
        String(saved.label || identity), String(saved.detail || ""), "app", identity, canonicalKey)
    } else if (source === "files" && identity.charAt(0) === "/") {
      row = root.makeRow("files", String(saved.icon || "󰈗"), "",
        String(saved.label || identity), String(saved.detail || ""), "file", identity, canonicalKey)
    } else if (source === "system") {
      var spec = root.systemSpec(identity)
      if (!spec) return null
      row = root.makeRow("system", spec.icon, "", spec.label, "", "exec", spec.action, canonicalKey)
    } else if (source === "ssh" && root.isSafeSshHost(identity)) {
      row = root.makeRow("ssh", "󰣀", "", "SSH " + identity, "Open terminal session",
        "exec", "xdg-terminal-exec -- ssh -- " + Util.shellQuote(identity), canonicalKey)
    } else {
      return null
    }
    row.score = -(Number(entry.count) || 0)
    return row
  }

  function favoriteRows() {
    var rows = []
    for (var key in root.usage) {
      var row = root.restoreUsageRow(root.usage[key], key)
      if (row) rows.push(row)
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
  property var appCandidates: []
  property bool appCandidatesReady: false

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

  // Stable row identity for content whose positional index changes between
  // asynchronous rebuilds. This is not a security hash.
  function stableHash(value) {
    var text = String(value || "")
    var hash = 5381
    for (var i = 0; i < text.length; i++)
      hash = ((hash << 5) + hash) ^ text.charCodeAt(i)
    return (hash >>> 0).toString(16) + "-" + text.length
  }

  function bestRows(rows, max) {
    rows.sort(function(a, b) {
      if (a.score !== b.score) return a.score - b.score
      return String(a.label || "").localeCompare(String(b.label || ""))
    })
    return rows.slice(0, Math.max(0, Number(max) || 0))
  }

  // -- apps ---------------------------------------------------------------

  function rebuildAppCandidates() {
    var candidates = []
    if (!root.appLibrary) {
      root.appCandidates = candidates
      root.appCandidatesReady = false
      return
    }
    var entries = root.appLibrary.sortedEntries("")
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
      candidates.push({
        appId: appId,
        name: name,
        subtext: subtext || "",
        haystack: haystack,
        icon: String(entry.icon || "")
      })
    }
    root.appCandidates = candidates
    root.appCandidatesReady = true
  }

  function appRows(query) {
    var rows = []
    if (!root.appLibrary) return rows
    if (!root.appCandidatesReady) root.rebuildAppCandidates()
    for (var i = 0; i < root.appCandidates.length; i++) {
      var candidate = root.appCandidates[i]
      var score = Fuzzy.score(query, candidate.haystack)
      if (score === null) continue
      var row = root.makeRow("apps", "", candidate.icon, candidate.name, candidate.subtext,
        "app", candidate.appId, "app:" + candidate.appId)
      row.score = score - root.usageBoost(row.rowKey)
      rows.push(row)
    }
    rows = root.bestRows(rows, root.configMaxResults())
    for (var j = 0; j < rows.length; j++)
      rows[j].appIcon = root.appLibrary.iconSource(rows[j].appIcon)
    return rows
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
      row.score = (score || 0) + 2 + i * 0.001
      rows.push(row)
    }
    return root.bestRows(rows, max)
  }

  function refreshWindows() {
    windowsProc.latestRun += 1
    windowsProc.pendingRun = windowsProc.latestRun
    windowsProc.pendingCommand = ["hyprctl", "-j", "clients"]
    windowsProc.pending = true
    if (windowsProc.running) windowsProc.running = false
    else root.startPendingWindows()
  }

  function startPendingWindows() {
    if (!windowsProc.pending || windowsProc.running) return
    windowsProc.activeRun = windowsProc.pendingRun
    windowsProc.collected = ""
    windowsProc.command = windowsProc.pendingCommand
    windowsProc.pending = false
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
      fdProc.latestRun += 1
      fdProc.pending = false
      fdProc.pendingCommand = []
      fdProc.running = false
      return
    }
    var pattern = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    var roots = root.configFileRoots()
    var command = [root.fileSearchPath(), "8", "30", "1.2", "0.2", pattern]
    for (var i = 0; i < roots.length; i++) {
      var path = root.homePath(roots[i])
      if (path) command.push(path)
    }
    root.queueFileSearch(query, command)
  }

  function queueFileSearch(query, command) {
    fdProc.latestRun += 1
    fdProc.pendingRun = fdProc.latestRun
    fdProc.pendingSerial = root.querySerial
    fdProc.pendingQuery = query
    fdProc.pendingCommand = command
    fdProc.pending = true
    if (fdProc.running) fdProc.running = false
    else root.startPendingFileSearch()
  }

  function startPendingFileSearch() {
    if (!fdProc.pending || fdProc.running) return
    fdProc.activeRun = fdProc.pendingRun
    fdProc.activeSerial = fdProc.pendingSerial
    fdProc.activeQuery = fdProc.pendingQuery
    fdProc.collected = ""
    fdProc.command = fdProc.pendingCommand
    fdProc.pending = false
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
      if (!root.isSafeSshHost(host)) continue
      var score = Fuzzy.score(query, host)
      if (score === null) continue
      var row = root.makeRow("ssh", "󰣀", "", "SSH " + host, "Open terminal session",
        "exec", "xdg-terminal-exec -- ssh -- " + Util.shellQuote(host), "ssh:" + host)
      row.score = score + 4 - root.usageBoost(row.rowKey) + i * 0.001
      rows.push(row)
    }
    return root.bestRows(rows, max)
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
          "clip:" + entry.stableKey)
      } else {
        row = root.makeRow("clipboard", "", "", entry.label, "Paste",
          "clipboard", String(entry.index), "clip:" + entry.stableKey)
      }
      row.score = score + 6 + i * 0.001
      rows.push(row)
    }
    return root.bestRows(rows, max)
  }

  // -- external providers ---------------------------------------------------------
  //
  // Executables in the shipped/user provider directories receive the query
  // as $1 and print TSV rows: label\tdetail\taction[\ticon].
  // A tracked helper runs them concurrently, enforces TERM+KILL deadlines,
  // bounds output, and streams each completed provider batch back immediately.

  property string userProvidersDir: Quickshell.env("HOME") + "/.config/omarchy/omnibox/providers"

  function pluginProvidersDir() {
    return root.pluginSourceDir() + "/providers"
  }

  function providerRunnerPath() {
    return root.pluginSourceDir() + "/bin/run-providers"
  }

  function scanProviders() {
    scanProc.pending = true
    if (!scanProc.running) root.startPendingProviderScan()
  }

  function startPendingProviderScan() {
    if (!scanProc.pending || scanProc.running) return
    scanProc.pending = false
    scanProc.collected = ""
    scanProc.command = ["bash", "-lc",
      "for dir in " + Util.shellQuote(root.pluginProvidersDir()) + " " + Util.shellQuote(root.userProvidersDir) + "; do "
      + "[[ -d $dir ]] || continue; "
      + "for f in \"$dir\"/*; do [[ -f $f && -x $f ]] || continue; printf '%s\\t%s\\n' \"${f##*/}\" \"$f\"; done; "
      + "done"]
    scanProc.running = true
  }

  function startProviderWatcher() {
    if (providerWatchProc.running) return
    providerWatchProc.command = ["bash", "-lc",
      "mkdir -p -- " + Util.shellQuote(root.userProvidersDir) + "; "
      + "exec inotifywait -mq -e close_write,create,delete,moved_to,moved_from,attrib "
      + "--format '%e' -- " + Util.shellQuote(root.userProvidersDir)]
    providerWatchProc.running = true
  }

  function runProviders(query) {
    providerPublishTimer.stop()
    root.providerRows = ({})
    if (root.opened) root.rebuildDisplay()

    if (!query || root.providerList.length === 0) {
      providersProc.latestRun += 1
      providersProc.pending = false
      providersProc.pendingCommand = []
      providersProc.running = false
      return
    }

    var command = [
      root.providerRunnerPath(),
      "0.9",   // SIGTERM deadline
      "0.2",   // SIGKILL grace
      "8",     // rows per provider
      "16384", // bytes per physical output line
      query
    ]
    for (var i = 0; i < root.providerList.length; i++) {
      command.push(root.providerList[i].name)
      command.push(root.providerList[i].path)
    }
    root.queueProviderSearch(query, command)
  }

  function queueProviderSearch(query, command) {
    providersProc.latestRun += 1
    providersProc.pendingRun = providersProc.latestRun
    providersProc.pendingSerial = root.querySerial
    providersProc.pendingQuery = query
    providersProc.pendingCommand = command
    providersProc.pending = true
    if (providersProc.running) providersProc.running = false
    else root.startPendingProviderSearch()
  }

  function startPendingProviderSearch() {
    if (!providersProc.pending || providersProc.running) return
    providersProc.activeRun = providersProc.pendingRun
    providersProc.activeSerial = providersProc.pendingSerial
    providersProc.activeQuery = providersProc.pendingQuery
    providersProc.command = providersProc.pendingCommand
    providersProc.pending = false
    providersProc.running = true
  }

  function acceptProviderLine(data) {
    if (providersProc.activeRun !== providersProc.latestRun
        || providersProc.activeSerial !== root.querySerial
        || providersProc.activeQuery !== root.currentQuery()) return
    var line = String(data || "").replace(/\r$/, "")
    if (!line) return
    var parts = line.split("\t")
    if (parts.length < 4) return
    var name = parts[0]
    var label = parts[1]
    var detail = parts[2]
    var action = parts[3]
    var icon = parts.length > 4 ? parts[4] : ""
    if (!name || !label || !action) return

    var next = ({})
    for (var key in root.providerRows)
      next[key] = root.providerRows[key].slice()
    var batch = next[name] || []
    if (batch.length >= 8) return
    batch.push({ label: label, detail: detail, action: action, icon: icon })
    next[name] = batch
    root.providerRows = next
    providerPublishTimer.restart()
  }

  function providerRowList(query) {
    var rows = []
    for (var i = 0; i < root.providerList.length; i++) {
      var name = root.providerList[i].name
      var batch = root.providerRows[name]
      if (!batch) continue
      for (var j = 0; j < batch.length; j++) {
        var parsed = batch[j]
        var detail = parsed.detail || name
        var row = root.makeRow("providers", parsed.icon || "󰐢", "", parsed.label,
          detail, "exec", parsed.action,
          "prov:" + name + ":" + root.stableHash(parsed.label + "\u0000" + detail + "\u0000" + parsed.action))
        var score = Fuzzy.score(query, parsed.label + " " + detail)
        row.score = score === null ? 100 + j : 50 + score + i * 0.001
        rows.push(row)
      }
    }
    return root.bestRows(rows, root.configMaxResults())
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

  function rebuildDisplay(preserveSelection) {
    var shouldPreserve = preserveSelection !== false
    var fallbackIndex = root.selectedIndex
    var selectedKey = ""
    if (shouldPreserve && fallbackIndex >= 0 && fallbackIndex < displayModel.count)
      selectedKey = String(displayModel.get(fallbackIndex).rowKey || "")

    root.disarmPointer()
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

    var restoredIndex = -1
    if (shouldPreserve && selectedKey) {
      for (var r = 0; r < displayModel.count; r++) {
        if (String(displayModel.get(r).rowKey || "") === selectedKey) {
          restoredIndex = r
          break
        }
      }
    }

    if (displayModel.count === 0) root.selectedIndex = 0
    else if (restoredIndex >= 0) root.selectedIndex = restoredIndex
    else if (!shouldPreserve) root.selectedIndex = 0
    else root.selectedIndex = Math.max(0, Math.min(fallbackIndex, displayModel.count - 1))

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  function onQueryChanged() {
    root.querySerial += 1
    root.fileRows = []
    root.providerRows = ({})
    root.stopAsyncSearch()
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay(false)

    var query = root.currentQuery()
    if (query && query.charAt(0) !== ">") searchTimer.restart()
    else searchTimer.stop()
  }

  function refreshDynamicSources() {
    if (!root.appCandidatesReady) root.rebuildAppCandidates()
    root.refreshWindows()
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

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function select(delta) {
    if (displayModel.count === 0) return
    var step = Number(delta)
    if (!isFinite(step) || step === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = ((root.selectedIndex + step) % displayModel.count + displayModel.count) % displayModel.count
    Qt.callLater(function() { root.revealCursor() })
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
    property int latestRun: 0
    property int pendingRun: 0
    property int activeRun: 0
    property var pendingCommand: []
    property bool pending: false
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { windowsProc.collected += data + "\n" }
    }
    onRunningChanged: if (!running) Qt.callLater(function() { root.startPendingWindows() })
    onExited: {
      if (windowsProc.activeRun !== windowsProc.latestRun) return
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
    property int latestRun: 0
    property int pendingRun: 0
    property int activeRun: 0
    property int pendingSerial: -1
    property int activeSerial: -1
    property string pendingQuery: ""
    property string activeQuery: ""
    property var pendingCommand: []
    property bool pending: false
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { fdProc.collected += data + "\n" }
    }
    onRunningChanged: if (!running) Qt.callLater(function() { root.startPendingFileSearch() })
    onExited: {
      if (fdProc.activeRun !== fdProc.latestRun
          || fdProc.activeSerial !== root.querySerial
          || fdProc.activeQuery !== root.currentQuery()) return
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
    property int latestRun: 0
    property int pendingRun: 0
    property int activeRun: 0
    property int pendingSerial: -1
    property int activeSerial: -1
    property string pendingQuery: ""
    property string activeQuery: ""
    property var pendingCommand: []
    property bool pending: false
    stdout: SplitParser {
      onRead: function(data) { root.acceptProviderLine(data) }
    }
    onRunningChanged: if (!running) Qt.callLater(function() { root.startPendingProviderSearch() })
    onExited: {
      if (providersProc.activeRun === providersProc.latestRun
          && providersProc.activeSerial === root.querySerial
          && providersProc.activeQuery === root.currentQuery())
        providerPublishTimer.restart()
    }
  }

  Process {
    id: scanProc
    property bool pending: false
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { scanProc.collected += data + "\n" }
    }
    onRunningChanged: if (!running) Qt.callLater(function() { root.startPendingProviderScan() })
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

  Process {
    id: providerWatchProc
    stdout: SplitParser {
      onRead: function(_data) { providerScanTimer.restart() }
    }
    onRunningChanged: if (!running) providerWatchRestartTimer.restart()
  }

  Timer {
    id: providerScanTimer
    interval: 120
    repeat: false
    onTriggered: root.scanProviders()
  }

  Timer {
    id: providerWatchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: root.startProviderWatcher()
  }

  Timer {
    id: providerPublishTimer
    interval: 16
    repeat: false
    onTriggered: if (root.opened) root.rebuildDisplay()
  }

  Timer {
    id: searchTimer
    interval: 220
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
        root.applyConfig(Jsonc.parse(text()))
      } catch (e) {
        root.configError = String((e && e.message) || e)
        console.warn("omnibox: keeping last valid config:", root.configError)
      }
    }
    onLoadFailed: {
      try { root.applyConfig({}) } catch (e) { }
    }
    onFileChanged: reload()
  }

  Process {
    id: usageWriterProc
    property string pendingPayload: ""
    property string activePayload: ""
    property bool pending: false
    stdinEnabled: true
    onStarted: usageWriterProc.write(usageWriterProc.activePayload + "\n")
    onRunningChanged: if (!running) Qt.callLater(function() { root.startUsageWrite() })
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0)
        console.warn("omnibox: secure usage write failed:", exitCode, exitStatus)
    }
  }

  FileView {
    id: usageView
    path: root.usagePath
    printErrors: false
    onLoaded: root.loadUsage(text())
    onLoadFailed: { root.usage = ({}) }
  }

  FileView {
    id: sshView
    path: Quickshell.env("HOME") + "/.ssh/config"
    watchChanges: true
    printErrors: false
    onLoaded: { root.parseSshConfig(text()) }
    onLoadFailed: {
      root.sshHosts = []
      if (root.opened) root.rebuildDisplay()
    }
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
    if (root.opened) root.rebuildDisplay()
  }

  FileView {
    id: clipView
    path: Quickshell.env("HOME") + "/.local/state/omarchy/clipboard-history.json"
    watchChanges: true
    printErrors: false
    onLoaded: { root.parseClipboard(text()) }
    onLoadFailed: {
      root.clipEntries = []
      if (root.opened) root.rebuildDisplay()
    }
    onFileChanged: reload()
  }

  function cappedClipboardText(raw) {
    var text = String(raw || "")
    var limit = 8192
    if (text.length <= limit) return text
    var cut = text.lastIndexOf("\n", limit)
    return text.slice(0, cut > 0 ? cut : limit)
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
          var rawText = String(item.text || "")
          var text = root.cappedClipboardText(rawText).replace(/\s+/g, " ").trim()
          if (!text) continue
          entries.push({
            index: i,
            type: "text",
            stableKey: "text:" + root.stableHash(rawText),
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
            stableKey: "image:" + root.stableHash(path + "\u0000" + String(item.mime || "image/png")),
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
      root.rebuildAppCandidates()
      if (root.opened) root.rebuildDisplay()
    }
  }

  Component.onCompleted: {
    root.scanProviders()
    root.startProviderWatcher()
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

  property int contentMargin: Style.spacing.popupPadding
  property int baseRowHeight: Math.max(Style.space(38), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int detailRowHeight: Math.max(Style.space(46),
    Style.font.title + Style.font.caption + Style.space(3) + Style.spacing.controlPaddingY * 2)
  property int rowSpacing: Style.spacing.xxs
  property int inputHeight: Style.space(44)
  property int sectionHeight: Style.space(18)
  property int maxRowsHeight: Style.space(420)
  property int layoutSerial: 0

  readonly property int cardWidth: Math.min(Style.space(460), Math.max(1, panel.width - Style.gapsOut * 2))
  readonly property int minimumCardHeight: root.cardBorderHeight + root.contentMargin * 2 + root.inputHeight
  readonly property int cardTop: {
    var preferred = Math.round(panel.height * 0.22)
    var latest = Math.max(Style.gapsOut, panel.height - root.minimumCardHeight - Style.gapsOut)
    return Math.max(Style.gapsOut, Math.min(preferred, latest))
  }
  readonly property int cardBorderHeight: Math.ceil(Border.top(root.borderSpec) + Border.bottom(root.borderSpec))

  function rowHeightFor(row) {
    return row.detail ? root.detailRowHeight : root.baseRowHeight
  }

  function availableRowsHeight() {
    var available = panel.height - root.cardTop - Style.gapsOut - root.cardBorderHeight
      - root.contentMargin * 2 - root.inputHeight - root.contentSpacing()
    return Math.max(0, available)
  }

  function contentSpacing() { return Style.spacing.md }

  function naturalRowsHeight(_serial) {
    if (displayModel.count === 0) return root.baseRowHeight
    var total = 0
    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (i > 0) total += root.rowSpacing
      if (row.section) total += root.sectionHeight
      total += root.rowHeightFor(row)
    }
    return total
  }

  function rowsHeight(_serial) {
    return Math.min(
      root.naturalRowsHeight(layoutSerial),
      root.maxRowsHeight,
      root.availableRowsHeight()
    )
  }

  property int cardHeight: root.cardBorderHeight + root.contentMargin * 2
    + root.inputHeight + root.contentSpacing() + root.rowsHeight(layoutSerial)

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

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
      height: Math.max(1, Math.min(root.cardHeight, panel.height - Style.gapsOut - root.cardTop))
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.cardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

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
          spacing: Style.spacing.lg

          Text {
            text: "󰈉"
            color: root.foreground
            opacity: 0.72
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
            anchors.verticalCenter: parent.verticalCenter
          }

          TextField {
            id: searchField
            width: Math.max(0, parent.width - Style.spacing.lg - Style.font.icon
              - (hintText.visible ? hintText.width + Style.spacing.xxl : 0))
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Apps, files, math, web…"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: root.foreground
            selectionColor: Util.alpha(root.foreground, 0.3)
            selectedTextColor: root.foreground
            placeholderTextColor: Util.alpha(root.foreground, 0.72)
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
            visible: text.length > 0 && parent.width >= Style.space(360)
            color: root.foreground
            opacity: 0.72
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
              height: section.length > 0 ? root.sectionHeight : 0
              visible: section.length > 0

              Text {
                text: section.toUpperCase()
                color: root.foreground
                opacity: 0.72
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
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
                width: Style.space(30)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
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
                anchors.leftMargin: Style.spacing.md + (Style.space(30) - width) / 2
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.left: (row.icon.length > 0 || row.appIcon.length > 0)
                  ? parent.left : parent.left
                anchors.leftMargin: (row.icon.length > 0 || row.appIcon.length > 0)
                  ? Style.space(42) : Style.spacing.xxl
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  text: row.label
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: row.detail
                  visible: row.detail.length > 0
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.hasCursor ? 1.0 : 0.72
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectFromPointer(row.index, row, {
                  x: mouseArea.mouseX,
                  y: mouseArea.mouseY
                })
                onPositionChanged: function(mouse) {
                  root.selectFromPointer(row.index, row, mouse)
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activateIndex(row.index, Qt.NoModifier)
                }
              }
            }
          }

          Rectangle {
            id: scrollThumb
            visible: resultList.height > 0 && resultList.contentHeight > resultList.height + 1
            width: Style.space(2)
            height: visible
              ? Math.max(Style.space(24), parent.height * resultList.visibleArea.heightRatio)
              : 0
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.xxs
            y: visible
              ? Math.max(0, Math.min(parent.height - height,
                  parent.height * resultList.visibleArea.yPosition))
              : 0
            radius: width / 2
            color: root.foreground
            opacity: 0.35
            z: 10
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

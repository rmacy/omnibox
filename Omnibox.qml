import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "js/Calc.js" as Calc
import "js/Fuzzy.js" as Fuzzy
import "js/Jsonc.js" as Jsonc
import "js/Actions.js" as Actions
import "js/Execution.js" as Execution
import "js/Flow.js" as Flow
import "js/Native.js" as Native
import "js/Query.js" as Query
import "js/Ranking.js" as Ranking
import "js/Registry.js" as Registry
import "js/Workflows.js" as Workflows

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
  property string interactionMode: "Search"
  property var flowState: Flow.create({}).value
  property var resultObjects: []
  property var actionObjects: []
  property var activeResult: null
  property var activeAction: null
  property int searchSelectedIndex: 0
  property string actionMessage: ""
  property string actionDetail: ""
  property bool actionSucceeded: true
  property int actionRunSerial: 0
  property string actionRunToken: ""
  property int activeArgumentIndex: 0
  property var argumentValues: ({})
  readonly property int maxActionOutputBytes: 16384
  property var nativeCommands: []
  property var nativeThemes: []
  property var nativeStates: ({})
  property bool nativeCatalogLoaded: false
  property string nativeCatalogError: ""
  readonly property int maxNativeCatalogBytes: 1048576
  property var projects: []
  property var validatedWorkflows: []
  property string projectsPath: Quickshell.env("HOME") + "/.local/state/omnibox/projects.json"
  property string projectScope: ""
  property string projectScopeTitle: ""
  property string projectScanError: ""
  property var workflowRuntime: null
  property var workflowPlan: null
  property var pendingWorkflowPlan: null
  property string workflowRunToken: ""
  property int workflowRunSerial: 0

  function resetInteraction() {
    var reset = Flow.reset({})
    root.flowState = reset.ok ? reset.value : ({ frames: [], runSerial: 0, activeToken: "", closed: false })
    root.interactionMode = "Search"
    root.activeResult = null
    root.activeAction = null
    root.activeArgumentIndex = 0
    root.argumentValues = ({})
    root.actionObjects = []
    root.actionMessage = ""
    root.actionSucceeded = true
    root.actionDetail = ""
    root.actionRunToken = ""
    root.projectScope = ""
    root.projectScopeTitle = ""
    root.workflowRuntime = null
    root.workflowPlan = null
    root.pendingWorkflowPlan = null
    root.workflowRunToken = ""
    root.searchSelectedIndex = 0
    actionModel.clear()
  }

  function interactionBreadcrumb() {
    var parts = []
    if (root.projectScope) parts.push(root.projectScopeTitle || "Project", "Files")
    if (root.flowState && root.flowState.frames) {
      for (var i = 1; i < root.flowState.frames.length; i++)
        parts.push(String(root.flowState.frames[i].title || root.flowState.frames[i].mode || ""))
    }
    return parts.join(" › ")
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.resetInteraction()
    root.opened = true
    root.selectedIndex = 0
    root.cursorActive = true
    searchField.text = String(payload.query || "")
    searchField.cursorPosition = searchField.text.length
    root.refreshDynamicSources()
    root.refreshNativeState()
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
    root.loadNativeCatalog(true)
    root.loadNativeThemes(true)
    root.refreshNativeState()
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
    if (root.interactionMode === "Running") root.cancelRunningAction()
    root.opened = false
    var hadQuery = searchField.text.length > 0
    root.resetInteraction()
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
  //   projects   opt-in roots/depth/cap for project discovery
  //   workflows  deterministic registered-action workflows

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
    "maxResults": 8,
    "projects": { "roots": [], "maxDepth": 4, "maxProjects": 200 },
    "workflows": []
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

  function configProjectRoots() {
    var projects = root.config.projects
    var roots = projects && projects.roots
    if (!Array.isArray(roots)) return []
    var resolved = []
    var seen = ({})
    for (var i = 0; i < roots.length && resolved.length < 16; i++) {
      var path = root.homePath(String(roots[i] || "")).replace(/\/+$/, "")
      if (path && path.charAt(0) === "/" && !seen[path]) {
        seen[path] = true
        resolved.push(path)
      }
    }
    return resolved
  }

  function configProjectDepth() {
    var value = Number(root.config.projects && root.config.projects.maxDepth)
    return isFinite(value) ? Math.max(1, Math.min(8, Math.floor(value))) : 4
  }

  function configProjectLimit() {
    var value = Number(root.config.projects && root.config.projects.maxProjects)
    return isFinite(value) ? Math.max(1, Math.min(500, Math.floor(value))) : 200
  }

  function configWorkflows() {
    return Array.isArray(root.config.workflows) ? root.config.workflows : []
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
    root.configureProjects()
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


  function systemSpec(id) {
    for (var i = 0; i < root.systemRows.length; i++)
      if (root.systemRows[i].id === id) return root.systemRows[i]
    return null
  }

  function isSafeSshHost(host) {
    return /^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(String(host || ""))
  }

  function usageKey(source, identity) {
    if (source === "apps") return "app:" + identity
    if (source === "files") return "file:" + identity
    if (source === "system") return "sys:" + identity
    if (source === "ssh") return "ssh:" + identity
    if (source === "native") return "native:" + root.stableHash(identity)
    if (source === "projects") return Workflows.projectId(identity)
    if (source === "workflows") return "workflow:" + identity
    return ""
  }

  function storedUsageIdentity(stored, fallbackKey) {
    if (!stored || typeof stored !== "object") return ""
    var source = String(stored.source || "")
    var id = String(stored.id || stored.rowKey || fallbackKey || "")
    var value = stored.value !== undefined ? stored.value
      : (stored.payload !== undefined ? stored.payload : stored.data)
    if (source === "apps") return String(value || "")
    if (source === "files") {
      var path = String(value || "")
      return path.charAt(0) === "/" ? path : ""
    }
    if (source === "system") {
      var systemId = id.indexOf("sys:") === 0 ? id.slice(4) : ""
      return root.systemSpec(systemId) ? systemId : ""
    }
    if (source === "projects") {
      var projectValue = String(value || "")
      try { projectValue = String(JSON.parse(projectValue).path || "") }
      catch (_projectStoredError) { }
      return Workflows.projectId(projectValue) === id ? projectValue : ""
    }
    if (source === "workflows") {
      var workflowValue = String(value || "")
      try { workflowValue = String(JSON.parse(workflowValue).id || "") }
      catch (_workflowStoredError) { }
      return Actions.stableId(workflowValue) && id === "workflow:" + workflowValue ? workflowValue : ""
    }
    if (source === "native") {
      var nativeValue = String(value || "")
      try {
        var nativeStored = JSON.parse(nativeValue)
        nativeValue = String(nativeStored.route || "")
      } catch (_nativeStoredError) { }
      return nativeValue.indexOf("omarchy ") === 0 ? nativeValue : ""
    }
    if (source === "ssh") {
      var host = id.indexOf("ssh:") === 0 ? id.slice(4) : String(value || "")
      return root.isSafeSshHost(host) ? host : ""
    }
    return ""
  }

  function sanitizeUsage(value) {
    var next = ({})
    var entries = value && value.version === 2 && value.entries ? value.entries : value
    if (!entries || typeof entries !== "object") return next
    for (var key in entries) {
      var entry = entries[key]
      var stored = entry && (entry.result || entry.row)
      if (!entry || !stored) continue
      var source = String(stored.source || "")
      var identity = root.storedUsageIdentity(stored, key)
      var canonicalKey = root.usageKey(source, identity)
      if (!identity || !canonicalKey) continue
      var count = Number(entry.count)
      var lastUsed = Number(entry.lastUsed)
      var alias = String(entry.alias || "").trim()
      if (!alias || alias.length > 80 || /[\r\n\t]/.test(alias)) alias = ""
      var actionId = Actions.stableId(String(entry.actionId || "")) ? String(entry.actionId) : ""
      next[canonicalKey] = {
        count: isFinite(count) && count > 0 ? count : 0,
        lastUsed: isFinite(lastUsed) && lastUsed > 0 ? lastUsed : 0,
        pinned: entry.pinned === true,
        alias: alias,
        actionId: actionId,
        result: {
          id: canonicalKey,
          source: source,
          type: source === "apps" ? "app" : (source === "files" ? "file"
            : (source === "ssh" ? "ssh" : (source === "projects" ? "project" : "command"))),
          icon: String(stored.icon || ""),
          appIcon: String(stored.appIcon || ""),
          title: String(stored.title || stored.label || identity),
          subtitle: String(stored.subtitle || stored.detail || ""),
          value: identity
        }
      }
    }
    return next
  }

  function loadUsage(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      root.usage = root.sanitizeUsage(parsed)
      // Rewrites legacy state into the v2 envelope atomically and keeps
      // the directory/file at 0700/0600.
      root.saveUsage()
    } catch (e) {
      root.usage = ({})
      console.warn("omnibox: refusing to overwrite invalid usage state:", e)
    }
  }

  function pluginSourceDir() {
    return root.manifest && root.manifest.__sourceDir
      ? String(root.manifest.__sourceDir)
      : Quickshell.env("HOME") + "/.config/omarchy/plugins/bitr0t.omnibox"
  }

  function usageWriterPath() {
    return root.pluginSourceDir() + "/bin/write-usage"
  }

  function fileSearchPath() {
    return root.pluginSourceDir() + "/bin/search-files"
  }

  function projectScannerPath() {
    return root.pluginSourceDir() + "/bin/scan-projects"
  }

  function projectWriterPath() {
    return root.pluginSourceDir() + "/bin/write-projects"
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
    root.queueUsageWrite(JSON.stringify({ version: 2, entries: root.usage }))
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

  function restoreUsageCandidate(entry, key) {
    var saved = entry && entry.result
    if (!saved) return null
    var source = String(saved.source || "")
    var identity = String(saved.value || "")
    var canonicalKey = root.usageKey(source, identity)
    if (!identity || !canonicalKey || canonicalKey !== key) return null

    var candidate
    if (source === "apps") {
      candidate = root.makeCandidate("apps", String(saved.icon || ""), String(saved.appIcon || ""),
        String(saved.title || identity), String(saved.subtitle || ""), "app", identity, canonicalKey)
    } else if (source === "files" && identity.charAt(0) === "/") {
      candidate = root.makeCandidate("files", String(saved.icon || "󰈗"), "",
        String(saved.title || identity), String(saved.subtitle || ""), "file", identity, canonicalKey)
    } else if (source === "system") {
      var spec = root.systemSpec(identity)
      if (!spec) return null
      candidate = root.makeCandidate("system", spec.icon, "", spec.label, "",
        spec.builtin ? "systemBuiltin" : (spec.argv ? "systemArgv" : "shell"),
        spec.builtin || (spec.argv ? spec.argv.join("\u0000") : spec.action), canonicalKey)
    } else if (source === "projects") {
      var project = root.projectByIdentity(identity)
      if (!project) return null
      candidate = root.makeCandidate("projects", "󰉋", "", project.name,
        root.shortPath(project.path) + (project.branch ? " · " + project.branch : ""),
        "projectSpec", JSON.stringify(project), project.id)
    } else if (source === "workflows") {
      for (var workflowIndex = 0; workflowIndex < root.validatedWorkflows.length; workflowIndex++) {
        if (root.validatedWorkflows[workflowIndex].id === identity) {
          var workflow = root.validatedWorkflows[workflowIndex]
          candidate = root.makeCandidate("workflows", "󰑮", "", workflow.title,
            workflow.steps.length + " deterministic steps", "workflowSpec",
            JSON.stringify(workflow), "workflow:" + workflow.id)
          break
        }
      }
      if (!candidate) return null
    } else if (source === "native") {
      candidate = root.nativeCandidateForRoute(identity)
      if (!candidate) return null
    } else if (source === "ssh" && root.isSafeSshHost(identity)) {
      candidate = root.makeCandidate("ssh", "󰣀", "", "SSH " + identity, "Open terminal session",
        "ssh", identity, canonicalKey)
    } else {
      return null
    }
    candidate.matchScore = entry.pinned ? -10000 : -(Number(entry.count) || 0)
    return candidate
  }

  function favoriteRows() {
    var rows = []
    for (var key in root.usage) {
      var candidate = root.restoreUsageCandidate(root.usage[key], key)
      if (candidate) rows.push(candidate)
    }
    rows.sort(function(a, b) {
      var aEntry = root.usage[a.id] || ({})
      var bEntry = root.usage[b.id] || ({})
      if (!!aEntry.pinned !== !!bEntry.pinned) return aEntry.pinned ? -1 : 1
      var recency = (Number(bEntry.lastUsed) || 0) - (Number(aEntry.lastUsed) || 0)
      return recency || (a.matchScore - b.matchScore)
    })
    return rows.slice(0, root.configMaxResults() + 1)
  }


  function sanitizeProjects(value) {
    var source = value && value.version === 1 ? value.projects : value
    if (!Array.isArray(source)) return []
    var projects = []
    var seen = ({})
    for (var i = 0; i < source.length && projects.length < root.configProjectLimit(); i++) {
      var input = source[i] || ({})
      var safeRemote = input.remote ? Workflows.normalizeRemote(input.remote) : ""
      var checked = Workflows.validateProject({
        id: input.id || Workflows.projectId(String(input.path || "")),
        name: input.name,
        path: input.path,
        marker: input.marker || ".git",
        branch: input.branch,
        remote: safeRemote,
        refreshedAt: Number(input.refreshedAt) || 0
      })
      if (!checked.ok || seen[checked.value.id]) continue
      seen[checked.value.id] = true
      projects.push(checked.value)
    }
    projects.sort(function(a, b) {
      var byName = a.name.localeCompare(b.name)
      return byName || a.path.localeCompare(b.path)
    })
    return projects
  }

  function loadProjects(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      var projects = root.sanitizeProjects(parsed)
      if (projects.length > 0 || (parsed && parsed.version === 1)) root.projects = projects
    } catch (error) {
      root.projectScanError = "Invalid project cache: " + error
    }
  }

  function saveProjects() {
    projectWriterProc.payload = JSON.stringify({
      version: 1, refreshedAt: Date.now(), projects: root.projects
    })
    if (projectWriterProc.running) {
      projectWriterProc.pending = true
      return
    }
    projectWriterProc.command = [root.projectWriterPath(), root.projectsPath]
    projectWriterProc.running = true
  }

  function publishProjects(projects) {
    root.projects = root.sanitizeProjects(projects)
    root.projectScanError = ""
    root.saveProjects()
    if (root.opened && root.interactionMode === "Search") root.rebuildDisplay(true)
  }

  function runProjectScan() {
    var roots = root.configProjectRoots()
    if (roots.length === 0) {
      root.projects = []
      return
    }
    projectScanProc.latestRun += 1
    projectScanProc.activeRun = projectScanProc.latestRun
    projectScanProc.projects = []
    projectScanProc.command = [root.projectScannerPath(),
      String(root.configProjectDepth()), String(root.configProjectLimit())].concat(roots)
    projectScanProc.running = true
    projectScanTimeout.restart()
  }

  function startProjectWatcher(force) {
    var roots = root.configProjectRoots()
    if (force && projectWatchProc.running) projectWatchProc.running = false
    if (roots.length === 0 || projectWatchProc.running) return
    projectWatchProc.command = ["inotifywait", "-mq", "-r",
      "-e", "create,delete,moved_to,moved_from",
      "--format", "%e", "--"].concat(roots)
    projectWatchProc.running = true
  }

  function configureProjects() {
    var workflows = Workflows.validateConfig(root.configWorkflows())
    if (workflows.ok) root.validatedWorkflows = workflows.value
    else if (root.configWorkflows().length > 0) root.configError = workflows.error
    root.startProjectWatcher(true)
    root.runProjectScan()
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
  property var sourceRegistry: null
  property bool appCandidatesReady: false

  readonly property var systemRows: [
    { id: "lock", icon: "󰌾", label: "Lock", aliases: "lock screen secure", action: "omarchy-system-lock" },
    { id: "clipboard", icon: "", label: "Clipboard", aliases: "paste history clipboard manager", action: "omarchy-shell shell toggle omarchy.clipboard" },
    { id: "emoji", icon: "", label: "Emoji", aliases: "emoji symbols emoticon", action: "omarchy-shell shell toggle omarchy.emojis" },
    { id: "theme", icon: "󰸌", label: "Theme", aliases: "themes appearance style", action: "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\"" },
    { id: "menu", icon: "󰣇", label: "Omarchy Menu", aliases: "omarchy menu settings preferences configure setup", action: "omarchy-menu toggle setup" },
    { id: "keybindings", icon: "󰌌", label: "Keybindings", aliases: "shortcuts keys help", action: "omarchy-menu-keybindings" },
    { id: "suspend", icon: "󰒲", label: "Suspend", aliases: "sleep suspend", action: "systemctl suspend" },
    { id: "logout", icon: "󰍃", label: "Log Out", aliases: "logout sign out log off", action: "omarchy-system-logout" },
    { id: "reboot", icon: "󰜉", label: "Reboot", aliases: "restart reboot", action: "omarchy-system-reboot" },
    { id: "shutdown", icon: "󰐥", label: "Shutdown", aliases: "shutdown power off turn off", action: "omarchy-system-shutdown" },
    { id: "version", icon: "󰋼", label: "Omarchy Version", aliases: "omarchy version system information", argv: ["omarchy", "version"] },
    { id: "learning", icon: "󰘦", label: "Inspect Omnibox Learning", aliases: "omnibox usage pins aliases learning", builtin: "inspectLearning" },
    { id: "reset-learning", icon: "󰑐", label: "Reset Omnibox Learning", aliases: "omnibox reset forget all usage aliases pins", builtin: "resetLearning" }
  ]

  function makeCandidate(source, icon, appIcon, title, subtitle, behavior, value, id) {
    return {
      source: source,
      icon: icon,
      iconFont: "",
      appIcon: appIcon,
      title: title,
      subtitle: subtitle,
      behavior: behavior,
      value: value,
      id: id,
      matchScore: 0
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
      if (a.matchScore !== b.matchScore) return a.matchScore - b.matchScore
      return String(a.title || "").localeCompare(String(b.title || ""))
    })
    return rows.slice(0, Math.max(0, Number(max) || 0))
  }

  function appendCheckedAction(actions, spec) {
    var checked = Actions.makeAction(spec)
    if (checked.ok) actions.push(checked.value)
    else console.warn("omnibox: rejected action", spec && spec.id, checked.error)
  }

  function learnableResultType(type) {
    return type === "app" || type === "file" || type === "command" || type === "ssh" || type === "project"
  }

  function appendLearningActions(actions, resultId, type) {
    if (!root.learnableResultType(type)) return
    var entry = root.usage[resultId] || ({})
    root.appendCheckedAction(actions, {
      id: entry.pinned ? "learning.unpin" : "learning.pin",
      title: entry.pinned ? "Unpin" : "Pin",
      executor: "builtin",
      builtin: "togglePin",
      lifecycle: "keepOpen",
      risk: "safe"
    })
    root.appendCheckedAction(actions, {
      id: "learning.alias",
      title: "Set alias",
      executor: "builtin",
      builtin: "setAlias",
      arguments: [{ id: "alias", type: "string", title: "Alias", required: true }],
      lifecycle: "keepOpen",
      risk: "safe"
    })
    if (entry.count || entry.pinned || entry.alias) {
      root.appendCheckedAction(actions, {
        id: "learning.forget",
        title: "Forget usage",
        executor: "builtin",
        builtin: "forgetUsage",
        lifecycle: "keepOpen",
        risk: "caution"
      })
    }
  }

  function resultIdForCandidate(candidate) {
    var id = String(candidate.id || "")
    if (Actions.stableId(id)) return id
    return String(candidate.source || "result") + ":" + root.stableHash(id)
  }

  function resultTypeForCandidate(candidate) {
    if (candidate.source === "apps") return "app"
    if (candidate.source === "windows") return "window"
    if (candidate.source === "files") return "file"
    if (candidate.source === "calc") return "calculation"
    if (candidate.source === "web") return "web"
    if (candidate.source === "run") return "shell"
    if (candidate.source === "system") return "command"
    if (candidate.source === "native") return "command"
    if (candidate.source === "projects") return "project"
    if (candidate.source === "workflows") return "command"
    if (candidate.source === "clipboard") return "clipboard"
    if (candidate.source === "ssh") return "ssh"
    return "provider"
  }

  function typedResultForCandidate(candidate) {
    var id = root.resultIdForCandidate(candidate)
    var type = root.resultTypeForCandidate(candidate)
    var payload = String(candidate.value === undefined || candidate.value === null ? "" : candidate.value)
    if (type === "window" && !/^0x[0-9a-fA-F]+$/.test(payload)) return null
    var allowLearning = true
    var actions = []

    if (type === "app") {
      root.appendCheckedAction(actions, {
        id: "app.open", title: "Open", executor: "builtin", builtin: "appOpen",
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "app.launch-new", title: "Launch new instance", executor: "builtin", builtin: "appOpen",
        lifecycle: "close", risk: "safe"
      })
    } else if (type === "window") {
      root.appendCheckedAction(actions, {
        id: "window.focus", title: "Focus", executor: "builtin", builtin: "windowFocus",
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "window.move-workspace", title: "Move to workspace", executor: "builtin", builtin: "windowMoveWorkspace",
        arguments: [{ id: "workspace", type: "workspace", title: "Workspace", required: true,
          values: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"] }],
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "window.move-monitor", title: "Move to monitor", executor: "builtin", builtin: "windowMoveMonitor",
        arguments: [{ id: "monitor", type: "monitor", title: "Monitor", required: true,
          values: ["+1", "-1"] }],
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "window.float", title: "Toggle floating", executor: "builtin", builtin: "windowFloat",
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "window.fullscreen", title: "Toggle tiled fullscreen", executor: "argv",
        argv: ["omarchy", "hyprland", "window", "tiled", "fullscreen", "toggle"],
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "window.close", title: "Close window", executor: "builtin", builtin: "windowClose",
        lifecycle: "close", risk: "destructive", confirm: true
      })
    } else if (type === "file") {
      root.appendCheckedAction(actions, {
        id: "file.open", title: "Open", executor: "argv", argv: ["xdg-open", payload],
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "file.reveal", title: "Reveal in file manager", executor: "builtin", builtin: "fileReveal",
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "file.edit", title: "Open in editor", executor: "argv",
        argv: ["omarchy", "launch", "editor", payload], lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "file.terminal", title: "Open terminal here", executor: "builtin", builtin: "fileTerminal",
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "file.copy-path", title: "Copy path", executor: "builtin", builtin: "copyValue",
        lifecycle: "keepOpen", risk: "safe"
      })
    } else if (type === "calculation") {
      root.appendCheckedAction(actions, {
        id: "calculation.copy", title: "Copy result", executor: "builtin", builtin: "copyValue",
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "calculation.paste", title: "Paste result", executor: "builtin", builtin: "pasteValue",
        lifecycle: "close", risk: "safe"
      })
    } else if (type === "web") {
      root.appendCheckedAction(actions, {
        id: "web.open", title: "Open", executor: "argv", argv: ["xdg-open", payload],
        lifecycle: "close", risk: "remote"
      })
      root.appendCheckedAction(actions, {
        id: "web.copy-url", title: "Copy URL", executor: "builtin", builtin: "copyValue",
        lifecycle: "keepOpen", risk: "safe"
      })
    } else if (type === "ssh") {
      var host = id.indexOf("ssh:") === 0 ? id.slice(4) : ""
      root.appendCheckedAction(actions, {
        id: "ssh.connect", title: "Connect", executor: "argv",
        argv: ["xdg-terminal-exec", "--", "ssh", "--", host],
        lifecycle: "close", risk: "remote"
      })
      root.appendCheckedAction(actions, {
        id: "ssh.copy-host", title: "Copy host", executor: "builtin", builtin: "copyIdentity",
        lifecycle: "keepOpen", risk: "safe"
      })
    } else if (candidate.behavior === "clipboardImage") {
      root.appendCheckedAction(actions, {
        id: "clipboard.copy-image", title: "Copy image again",
        executor: "builtin", builtin: "clipboardImageCopy",
        lifecycle: "close", risk: "safe"
      })
    } else if (candidate.behavior === "clipboard") {
      root.appendCheckedAction(actions, {
        id: "clipboard.paste", title: "Paste", executor: "builtin", builtin: "clipboardPaste",
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "clipboard.copy-again", title: "Copy again", executor: "builtin", builtin: "clipboardCopy",
        lifecycle: "keepOpen", risk: "safe"
      })
    } else if (candidate.behavior === "copy") {
      root.appendCheckedAction(actions, {
        id: type === "web" ? "web.copy" : "calculation.copy",
        title: "Copy", executor: "builtin", builtin: "copyValue",
        lifecycle: "close", risk: "safe"
      })
    } else if (candidate.behavior === "projectSpec") {
      var projectSpec
      try { projectSpec = JSON.parse(payload) } catch (_projectSpecError) { return null }
      var resumeRemote = !!(projectSpec.remote && root.config.projects
        && root.config.projects.openRemote === true)
      root.appendCheckedAction(actions, {
        id: "project.resume", title: "Resume project", executor: "workflow",
        workflowId: "project.resume", lifecycle: "keepOpen",
        risk: resumeRemote ? "remote" : "safe", confirm: resumeRemote
      })
      root.appendCheckedAction(actions, {
        id: "project.edit", title: "Open in editor", executor: "argv",
        argv: ["omarchy", "launch", "editor", projectSpec.path],
        lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "project.terminal", title: "Open terminal", executor: "builtin",
        builtin: "projectTerminal", lifecycle: "close", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "project.search-files", title: "Search project files", executor: "builtin",
        builtin: "projectSearch", lifecycle: "keepOpen", risk: "safe"
      })
      root.appendCheckedAction(actions, {
        id: "project.copy-path", title: "Copy project path", executor: "builtin",
        builtin: "projectCopyPath", lifecycle: "keepOpen", risk: "safe"
      })
      if (projectSpec.remote) {
        root.appendCheckedAction(actions, {
          id: "project.open-remote", title: "Open Git remote", executor: "argv",
          argv: ["xdg-open", projectSpec.remote], lifecycle: "close", risk: "remote"
        })
      }
    } else if (candidate.behavior === "workflowSpec") {
      var workflowSpec
      try { workflowSpec = JSON.parse(payload) } catch (_workflowSpecError) { return null }
      var workflowHasRemote = false
      for (var workflowStep = 0; workflowStep < workflowSpec.steps.length; workflowStep++)
        if (workflowSpec.steps[workflowStep].action === "project.open-git-remote") workflowHasRemote = true
      var projectValues = []
      for (var projectIndex = 0; projectIndex < root.projects.length; projectIndex++)
        projectValues.push(root.projects[projectIndex].path)
      root.appendCheckedAction(actions, {
        id: "workflow.run", title: "Run workflow", executor: "workflow",
        workflowId: workflowSpec.id,
        arguments: [{ id: "project", type: "project", title: "Project", required: true,
          values: projectValues }],
        lifecycle: "keepOpen", risk: workflowHasRemote ? "remote" : "safe",
        confirm: workflowHasRemote
      })
    } else if (candidate.behavior === "nativeCatalogError") {
      allowLearning = false
      root.appendCheckedAction(actions, {
        id: "native.reload-catalog",
        title: "Reload command catalog",
        executor: "builtin",
        builtin: "reloadNativeCatalog",
        lifecycle: "keepOpen",
        risk: "caution"
      })
    } else if (candidate.behavior === "nativeSpec") {
      var nativeSpec
      try { nativeSpec = JSON.parse(payload) } catch (_nativeError) { return null }
      allowLearning = nativeSpec.learnable === true
      if (nativeSpec.argumentFields && nativeSpec.argumentFields.length > 0) {
        root.appendCheckedAction(actions, {
          id: "native.run-template",
          title: "Choose options",
          executor: "builtin",
          builtin: "runNativeTemplate",
          arguments: nativeSpec.argumentFields,
          lifecycle: nativeSpec.lifecycle || "close",
          risk: nativeSpec.risk || "safe",
          confirm: nativeSpec.confirm === true
        })
      } else if (nativeSpec.requiredArgs) {
        root.appendCheckedAction(actions, {
          id: "native.run-with-arguments",
          title: "Run with arguments",
          executor: "builtin",
          builtin: "runNativeWithArguments",
          arguments: [{ id: "arguments", type: "string", title: nativeSpec.args || "Arguments", required: true }],
          lifecycle: nativeSpec.lifecycle || "keepOpen",
          risk: nativeSpec.risk || "safe",
          confirm: nativeSpec.confirm === true
        })
      } else {
        root.appendCheckedAction(actions, {
          id: "native.run",
          title: "Run",
          executor: "argv",
          argv: nativeSpec.argv || [],
          lifecycle: nativeSpec.lifecycle || "keepOpen",
          risk: nativeSpec.risk || "safe",
          confirm: nativeSpec.confirm === true
        })
      }
      root.appendCheckedAction(actions, {
        id: "native.inspect",
        title: "Inspect command",
        executor: "builtin",
        builtin: "inspectNativeCommand",
        lifecycle: "keepOpen",
        risk: "safe"
      })
    } else if (candidate.behavior === "systemArgv") {
      root.appendCheckedAction(actions, {
        id: "command.run", title: "Run", executor: "argv",
        argv: payload.split("\u0000"), lifecycle: "keepOpen", risk: "safe"
      })
    } else if (candidate.behavior === "systemBuiltin") {
      var resetLearning = candidate.value === "resetLearning"
      root.appendCheckedAction(actions, {
        id: resetLearning ? "learning.reset-all" : "learning.inspect",
        title: resetLearning ? "Reset all learning" : "Inspect learning",
        executor: "builtin",
        builtin: String(candidate.value),
        lifecycle: "keepOpen",
        risk: resetLearning ? "destructive" : "safe",
        confirm: resetLearning
      })
    } else {
      var destructive = id === "sys:logout" || id === "sys:reboot" || id === "sys:shutdown"
      root.appendCheckedAction(actions, {
        id: type + ".run", title: type === "web" ? "Open" : "Run",
        executor: "shell", command: payload, trusted: true,
        lifecycle: type === "shell" && id.indexOf("run:t:") === 0 ? "terminal" : "close",
        risk: destructive ? "destructive" : (type === "web" ? "remote" : "caution"),
        confirm: destructive
      })
    }

    if (allowLearning) root.appendLearningActions(actions, id, type)
    var checked = Actions.makeResult({
      id: id,
      type: type,
      source: String(candidate.source || "providers"),
      title: String(candidate.title || "Result"),
      subtitle: String(candidate.subtitle || ""),
      icon: String(candidate.icon || ""),
      appIcon: String(candidate.appIcon || ""),
      value: { payload: payload, behavior: String(candidate.behavior || ""), candidateId: String(candidate.id || "") },
      matchScore: Number(candidate.matchScore) || 0,
      actions: actions
    })
    if (!checked.ok) {
      console.warn("omnibox: rejected result", id, checked.error)
      return null
    }
    return checked.value
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
      var row = root.makeCandidate("apps", "", candidate.icon, candidate.name, candidate.subtext,
        "app", candidate.appId, "app:" + candidate.appId)
      row.matchScore = score
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
      var row = root.makeCandidate("windows", "󰍲", "", label, detail,
        "window", String(win.address || ""), "win:" + String(win.address || ""))
      row.matchScore = (score || 0) + 2 + i * 0.001
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
      var row = root.makeCandidate("files", root.fileIcon(base, isDir), "",
        base, root.shortPath(dir), "file", path, "file:" + raw)
      row.matchScore = 28 + i * 2
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
    var roots = root.projectScope ? [root.projectScope] : root.configFileRoots()
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
    var row = root.makeCandidate("calc", "󰃬", "", "= " + result.display,
      "Copy result", "copy", String(result.display), "calc")
    row.matchScore = -100
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
      var row = root.makeCandidate("web", "󰖟", "", "Open " + url.replace(/^https:\/\//, ""),
        "Open in browser", "url", url, "url:" + url)
      row.matchScore = -20
      rows.push(row)
    }

    var engines = root.configEngines()
    var first = true
    for (var name in engines) {
      var template = String(engines[name] || "")
      if (!template) continue
      var target = template.split("%s").join(encodeURIComponent(q))
      var searchRow = root.makeCandidate("web", "󰈉", "",
        "Search " + name + " for “" + q + "”", "",
        "url", target, "web:" + root.stableHash(name))
      searchRow.matchScore = first ? 130 : 150
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
      root.makeCandidate("run", "", "", "Run in terminal: " + cmd, "", "shell", terminal, "run:t:" + root.stableHash(cmd)),
      root.makeCandidate("run", "󰧑", "", "Run in background: " + cmd, "", "shell", cmd, "run:b:" + root.stableHash(cmd))
    ]
    rows[0].matchScore = 0
    rows[1].matchScore = 1
    return rows
  }

  // -- system ----------------------------------------------------------------

  function systemRowList(query) {
    var rows = []
    for (var i = 0; i < root.systemRows.length; i++) {
      var spec = root.systemRows[i]
      var score = query ? Fuzzy.score(query, spec.label + " " + spec.aliases) : 100 + i
      if (query && score === null) continue
      var behavior = spec.builtin ? "systemBuiltin" : (spec.argv ? "systemArgv" : "shell")
      var value = spec.builtin || (spec.argv ? spec.argv.join("\u0000") : spec.action)
      var row = root.makeCandidate("system", spec.icon, "", spec.label, "",
        behavior, value, "sys:" + spec.id)
      row.matchScore = (score || 0) + 8
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
      var row = root.makeCandidate("ssh", "󰣀", "", "SSH " + host, "Open terminal session",
        "ssh", host, "ssh:" + host)
      row.matchScore = score + 4 + i * 0.001
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
        row = root.makeCandidate("clipboard", "󰋩", "", entry.label, "Image — copy again",
          "clipboardImage", entry.mime + "\u0000" + entry.data, "clip:" + entry.stableKey)
      } else {
        row = root.makeCandidate("clipboard", "", "", entry.label, "Paste",
          "clipboard", String(entry.index), "clip:" + entry.stableKey)
      }
      row.matchScore = score + 6 + i * 0.001
      rows.push(row)
    }
    return root.bestRows(rows, max)
  }


  // -- native Omarchy commands -----------------------------------------------

  function nativeCandidateFromSpec(spec) {
    var identity = String(spec.route || (spec.argv || []).join("\u0000"))
    var id = "native:" + root.stableHash(identity)
    var candidate = root.makeCandidate("native", String(spec.icon || "󰣇"), "",
      String(spec.title || spec.summary || spec.route || "Omarchy command"),
      String(spec.subtitle || spec.route || ""),
      "nativeSpec", JSON.stringify(spec), id)
    candidate.matchScore = Number(spec.matchScore) || 0
    return candidate
  }

  function nativeCandidateForCommand(command, matchScore) {
    if (!command) return null
    var policy = command.policy || Native.classify(command)
    var argv = Native.routeArgv(command.route)
    if (argv.length === 0) return null
    var forceRequired = command.route === "omarchy audio output volume"
    var requiredArgs = forceRequired || Native.hasRequiredArgs(command.args)
    return root.nativeCandidateFromSpec({
      route: command.route,
      title: command.summary || command.route,
      subtitle: command.route + (command.args ? " " + command.args : ""),
      argv: argv,
      args: command.args || "",
      examples: command.examples || [],
      aliases: command.aliases || [],
      requiredArgs: requiredArgs,
      interactive: policy.interactive,
      requiresSudo: command.requires_sudo === true,
      risk: policy.risk,
      lifecycle: policy.lifecycle,
      confirm: policy.confirm,
      matchScore: Number(matchScore) || 0,
      learnable: !requiredArgs && !policy.destructive && !policy.interactive,
      provenance: "omarchy commands --json"
    })
  }

  function nativeCandidateForRoute(route) {
    for (var i = 0; i < root.nativeCommands.length; i++)
      if (root.nativeCommands[i].route === route)
        return root.nativeCandidateForCommand(root.nativeCommands[i], 0)
    return null
  }

  function nativeRows(query) {
    var rows = []
    var seen = ({})
    if (root.nativeCatalogError && Fuzzy.score(query, "command catalog unavailable error") !== null) {
      var errorCandidate = root.makeCandidate("native", "󰅙", "",
        "Omarchy command catalog unavailable", root.nativeCatalogError,
        "nativeCatalogError", root.nativeCatalogError, "native:catalog-error")
      errorCandidate.matchScore = -80
      rows.push(errorCandidate)
      seen[errorCandidate.id] = true
    }
    var intents = Native.intentRows(query, {
      themes: root.nativeThemes,
      states: root.nativeStates,
      scoreFn: Fuzzy.score
    })
    for (var i = 0; i < intents.length; i++) {
      var intentCandidate = root.nativeCandidateFromSpec(intents[i])
      if (!seen[intentCandidate.id]) {
        seen[intentCandidate.id] = true
        rows.push(intentCandidate)
      }
    }
    var matches = Native.search(root.nativeCommands, query, Fuzzy.score, root.configMaxResults())
    for (i = 0; i < matches.length; i++) {
      var commandCandidate = root.nativeCandidateForCommand(matches[i], 36 + matches[i].matchScore)
      if (commandCandidate && !seen[commandCandidate.id]) {
        seen[commandCandidate.id] = true
        rows.push(commandCandidate)
      }
    }
    return root.bestRows(rows, root.configMaxResults())
  }


  function nativeStateRunnerPath() {
    return root.pluginSourceDir() + "/bin/native-state"
  }

  function loadNativeCatalog(force) {
    if (nativeCatalogProc.running) return
    if (root.nativeCatalogLoaded && !force) return
    nativeCatalogProc.collected = ""
    nativeCatalogProc.command = ["omarchy", "commands", "--json"]
    nativeCatalogProc.running = true
  }

  function loadNativeThemes(force) {
    if (nativeThemesProc.running) return
    if (root.nativeThemes.length > 0 && !force) return
    nativeThemesProc.collected = ""
    nativeThemesProc.command = ["omarchy", "theme", "list"]
    nativeThemesProc.running = true
  }

  function refreshNativeState() {
    if (nativeStateProc.running) return
    nativeStateProc.collected = ""
    nativeStateProc.command = [root.nativeStateRunnerPath()]
    nativeStateProc.running = true
  }


  // -- projects and workflows -----------------------------------------------

  function projectByIdentity(identity) {
    var value = String(identity || "")
    for (var i = 0; i < root.projects.length; i++)
      if (root.projects[i].id === value || root.projects[i].path === value) return root.projects[i]
    return null
  }

  function findProjectWindow(project, terminalOnly) {
    var nameNeedle = String(project && project.name || "").toLowerCase()
    var sessionNeedle = Workflows.sessionName(project).toLowerCase()
    for (var i = 0; i < root.windows.length; i++) {
      var win = root.windows[i]
      var title = String(win.title || "").toLowerCase()
      var klass = String(win.class || "").toLowerCase()
      var terminal = /ghostty|foot|kitty|alacritty|terminal/.test(klass)
      if (terminalOnly && !terminal) continue
      if (!terminalOnly && terminal) continue
      if ((nameNeedle && title.indexOf(nameNeedle) >= 0)
          || (sessionNeedle && title.indexOf(sessionNeedle) >= 0)) return win
    }
    return null
  }

  function focusProjectWindow(project, terminalOnly) {
    var win = root.findProjectWindow(project, terminalOnly)
    var address = String(win && win.address || "")
    if (!/^0x[0-9a-fA-F]+$/.test(address)) return false
    Util.execArgv(["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + address + '" })'])
    return true
  }

  function projectRows(query) {
    var rows = []
    for (var i = 0; i < root.projects.length; i++) {
      var project = root.projects[i]
      var haystack = [project.name, project.path, project.branch, project.remote].join(" ")
      var score = Fuzzy.score(query, haystack)
      if (score === null) continue
      var detail = root.shortPath(project.path)
      if (project.branch) detail += " · " + project.branch
      var candidate = root.makeCandidate("projects", "󰉋", "", project.name, detail,
        "projectSpec", JSON.stringify(project), project.id)
      candidate.matchScore = score + 1
      rows.push(candidate)
    }
    return root.bestRows(rows, root.configMaxResults())
  }

  function workflowRows(query) {
    var rows = []
    for (var i = 0; i < root.validatedWorkflows.length; i++) {
      var workflow = root.validatedWorkflows[i]
      var score = Fuzzy.score(query, workflow.title + " " + workflow.aliases.join(" "))
      if (score === null) continue
      var candidate = root.makeCandidate("workflows", "󰑮", "", workflow.title,
        workflow.steps.length + " deterministic steps", "workflowSpec",
        JSON.stringify(workflow), "workflow:" + workflow.id)
      candidate.matchScore = score + 2
      rows.push(candidate)
    }
    return root.bestRows(rows, root.configMaxResults())
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
        var row = root.makeCandidate("providers", parsed.icon || "󰐢", "", parsed.label,
          detail, "providerShell", parsed.action,
          "prov:" + name + ":" + root.stableHash(parsed.label + "\u0000" + detail + "\u0000" + parsed.action))
        var score = Fuzzy.score(query, parsed.label + " " + detail)
        row.matchScore = score === null ? 100 + j : 50 + score + i * 0.001
        rows.push(row)
      }
    }
    return root.bestRows(rows, root.configMaxResults())
  }

  // ------------------------------------------------------------- display

  ListModel { id: displayModel }
  ListModel { id: actionModel }

  readonly property var sourceLabels: ({
    calc: "Calculator", apps: "Apps", windows: "Windows", files: "Files",
    clipboard: "Clipboard", system: "System", web: "Web", ssh: "SSH",
    run: "Shell", native: "Commands", projects: "Projects", workflows: "Workflows", providers: "Provider"
  })

  function buildSourceRegistry() {
    var built = Registry.build([
      { id: "calc", label: "Calculator", order: 0,
        collect: function(_parsed, context) { return root.calcRows(context.query) } },
      { id: "apps", label: "Apps", order: 1,
        collect: function(_parsed, context) { return root.appRows(context.query) } },
      { id: "windows", label: "Windows", order: 2,
        collect: function(_parsed, context) { return root.windowRows(context.query) } },
      { id: "files", label: "Files", order: 3,
        collect: function(_parsed, context) { return root.fileRowsFromBatch(context.query) } },
      { id: "clipboard", label: "Clipboard", order: 4,
        collect: function(_parsed, context) { return root.clipboardRows(context.query) } },
      { id: "system", label: "System", order: 5,
        collect: function(_parsed, context) { return root.systemRowList(context.query) } },
      { id: "web", label: "Web", order: 6,
        collect: function(_parsed, context) { return root.webRows(context.query) } },
      { id: "ssh", label: "SSH", order: 7,
        available: function(context) { return context.query.length >= 2 },
        collect: function(_parsed, context) { return root.sshRows(context.query) } },
      { id: "native", label: "Commands", order: 8,
        collect: function(_parsed, context) { return root.nativeRows(context.query) } },
      { id: "projects", label: "Projects", order: 9,
        available: function(_context) { return root.projects.length > 0 },
        collect: function(_parsed, context) { return root.projectRows(context.query) } },
      { id: "workflows", label: "Workflows", order: 10,
        available: function(_context) { return root.validatedWorkflows.length > 0 },
        collect: function(_parsed, context) { return root.workflowRows(context.query) } },
      { id: "providers", label: "Providers", order: 11,
        collect: function(_parsed, context) { return root.providerRowList(context.query) } }
    ])
    root.sourceRegistry = built.ok ? built.value : null
    if (!built.ok) console.warn("omnibox: source registry rejected:", built.error)
  }

  function currentQuery() {
    return searchField.text.trim()
  }

  function rankingSignals() {
    var pins = ({})
    var rankedUsage = ({})
    for (var key in root.usage) {
      var entry = root.usage[key]
      if (!entry || typeof entry !== "object") continue
      if (entry.pinned) pins[key] = true
      rankedUsage[key] = {
        count: Number(entry.count) || 0,
        lastUsed: Number(entry.lastUsed) || 0
      }
    }
    return {
      pins: pins,
      usage: rankedUsage,
      now: Date.now(),
      sourcePriors: { calc: -5, apps: 0, windows: 1, files: 2, system: 2, clipboard: 3, web: 4, ssh: 4, providers: 5 }
    }
  }

  function learnedAliases() {
    var aliases = ({})
    for (var id in root.usage) {
      var alias = String(root.usage[id] && root.usage[id].alias || "").trim()
      if (alias) aliases[alias] = { resultId: id, actionId: String(root.usage[id].actionId || "") }
    }
    return aliases
  }

  function rebuildDisplay(preserveSelection) {
    var shouldPreserve = preserveSelection !== false
    var searchActive = root.interactionMode === "Search"
    var fallbackIndex = searchActive ? root.selectedIndex : root.searchSelectedIndex
    var selectedKey = ""
    if (shouldPreserve && fallbackIndex >= 0 && fallbackIndex < root.resultObjects.length)
      selectedKey = String(root.resultObjects[fallbackIndex].id || "")

    root.disarmPointer()
    displayModel.clear()

    var query = root.currentQuery()
    var parsed = Query.parse(query, root.learnedAliases())
    var rows = []

    if (root.projectScope) {
      rows = query ? root.fileRowsFromBatch(query) : []
    } else if (!query) {
      rows = root.favoriteRows()
      var seenEmpty = ({})
      for (var emptyIndex = 0; emptyIndex < rows.length; emptyIndex++) seenEmpty[rows[emptyIndex].id] = true
      var suggestions = root.systemRowList("")
      for (var suggestionIndex = 0; suggestionIndex < suggestions.length; suggestionIndex++) {
        if (!seenEmpty[suggestions[suggestionIndex].id]) rows.push(suggestions[suggestionIndex])
      }
      for (var f = 0; f < rows.length; f++) rows[f].matchScore = f
    } else if (parsed.mode === "Shell") {
      rows = root.runRows(query)
    } else {
      if (!root.sourceRegistry) root.buildSourceRegistry()
      var collected = Registry.collect(root.sourceRegistry, parsed, { query: query })
      if (collected.ok) {
        rows = collected.value.results
        for (var d = 0; d < collected.value.diagnostics.length; d++)
          console.warn("omnibox: source failed", collected.value.diagnostics[d].source,
            collected.value.diagnostics[d].error)
      }
    }

    var typedRows = []
    for (var i = 0; i < rows.length; i++) {
      var typed = root.typedResultForCandidate(rows[i])
      if (!typed) continue
      var learned = root.usage[typed.id]
      if (learned && learned.alias) typed.aliases = [String(learned.alias)]
      if (parsed.aliasResultId === typed.id) typed.matchScore = -100
      typedRows.push(typed)
    }
    var ranked = Ranking.rank(parsed.body || query, typedRows, root.rankingSignals())
    if (!query) ranked = typedRows
    var globalLimit = Math.max(root.configMaxResults(), root.configMaxResults() * 3)
    root.resultObjects = ranked.slice(0, globalLimit)

    for (i = 0; i < root.resultObjects.length; i++) {
      var result = root.resultObjects[i]
      var primary = result.actions.length > 0 ? result.actions[0].title : ""
      displayModel.append({
        resultId: result.id,
        resultType: result.type,
        source: result.source,
        sourceBadge: root.sourceLabels[result.source] || result.source,
        icon: result.icon || "",
        iconFont: "",
        appIcon: result.appIcon || "",
        label: result.title,
        detail: result.subtitle || "",
        actionHint: result.actions.length > 1 ? primary + " · Tab actions" : primary,
        section: ""
      })
    }

    layoutSerial += 1

    var restoredIndex = -1
    if (shouldPreserve && selectedKey) {
      for (var r = 0; r < root.resultObjects.length; r++) {
        if (String(root.resultObjects[r].id || "") === selectedKey) {
          restoredIndex = r
          break
        }
      }
    }

    var nextIndex = 0
    if (root.resultObjects.length === 0) nextIndex = 0
    else if (restoredIndex >= 0) nextIndex = restoredIndex
    else if (!shouldPreserve) nextIndex = 0
    else nextIndex = Math.max(0, Math.min(fallbackIndex, root.resultObjects.length - 1))
    if (searchActive) root.selectedIndex = nextIndex
    else root.searchSelectedIndex = nextIndex

    Qt.callLater(function() {
      if (root.interactionMode === "Search" && displayModel.count > 0) root.revealCursor()
    })
  }

  function onQueryChanged() {
    if (root.interactionMode !== "Search") {
      var updated = Flow.setQuery(root.flowState, searchField.text)
      if (updated.ok) root.flowState = updated.value
      root.selectedIndex = 0
      root.cursorActive = true
      root.rebuildInteractionModel()
      return
    }
    root.querySerial += 1
    root.fileRows = []
    root.providerRows = ({})
    root.stopAsyncSearch()
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay(false)

    var query = root.currentQuery()
    if (query && Query.parse(query, null).mode !== "Shell") searchTimer.restart()
    else searchTimer.stop()
  }

  function refreshDynamicSources() {
    if (!root.appCandidatesReady) root.rebuildAppCandidates()
    root.refreshWindows()
  }

  // ------------------------------------------------------------ interaction

  function activeModelCount() {
    return root.interactionMode === "Search" ? displayModel.count : actionModel.count
  }

  function activeObject(index) {
    if (root.interactionMode === "Search")
      return index >= 0 && index < root.resultObjects.length ? root.resultObjects[index] : null
    return index >= 0 && index < root.actionObjects.length ? root.actionObjects[index] : null
  }

  function currentMode() { return root.interactionMode }
  function actionStatus() {
    return JSON.stringify({
      mode: root.interactionMode,
      success: root.actionSucceeded,
      message: root.actionMessage,
      detail: root.actionDetail
    })
  }

  function objectIdAt(index) {
    var object = root.activeObject(Number(index))
    return object ? String(object.id || "") : ""
  }

  function detailAt(index) {
    var model = root.interactionMode === "Search" ? displayModel : actionModel
    var value = Number(index)
    return value >= 0 && value < model.count ? String(model.get(value).detail || "") : ""
  }

  function stageAActionMatrix() {
    var candidates = [
      root.makeCandidate("apps", "", "", "App", "", "app", "org.example.App", "app:org.example.App"),
      root.makeCandidate("windows", "", "", "Window", "", "window", "0x1", "win:0x1"),
      root.makeCandidate("files", "", "", "File", "", "file", "/tmp/example.txt", "file:/tmp/example.txt"),
      root.makeCandidate("calc", "", "", "42", "", "copy", "42", "calc"),
      root.makeCandidate("web", "", "", "Web", "", "url", "https://example.com", "url:https://example.com"),
      root.makeCandidate("run", "", "", "Shell", "", "shell", "true", "run:t:smoke"),
      root.makeCandidate("system", "", "", "Shutdown", "", "shell", "omarchy-system-shutdown", "sys:shutdown"),
      root.makeCandidate("clipboard", "", "", "Clipboard", "", "clipboard", "0", "clip:smoke"),
      root.makeCandidate("ssh", "", "", "SSH host", "", "ssh", "example-host", "ssh:example-host"),
      root.makeCandidate("providers", "", "", "Provider", "", "providerShell", "true", "prov:smoke")
    ]
    var matrix = ({})
    for (var i = 0; i < candidates.length; i++) {
      var result = root.typedResultForCandidate(candidates[i])
      var ids = []
      if (result) {
        for (var j = 0; j < result.actions.length; j++) ids.push(result.actions[j].id)
        matrix[result.source] = ids
      }
    }
    return JSON.stringify(matrix)
  }

  function nativeCatalogStatus() {
    return JSON.stringify({
      loaded: root.nativeCatalogLoaded,
      count: root.nativeCommands.length,
      error: root.nativeCatalogError,
      themes: root.nativeThemes.length,
      states: root.nativeStates
    })
  }

  function nativeCommandCount() { return root.nativeCommands.length }

  function nativePreview(query) {
    var candidates = root.nativeRows(String(query || ""))
    var preview = []
    for (var i = 0; i < candidates.length; i++) {
      var result = root.typedResultForCandidate(candidates[i])
      if (!result) continue
      var actions = []
      for (var j = 0; j < result.actions.length; j++) actions.push(result.actions[j].id)
      preview.push({ id: result.id, title: result.title, actions: actions,
        confirm: result.actions.length > 0 && result.actions[0].confirm,
        risk: result.actions.length > 0 ? result.actions[0].risk : "",
        lifecycle: result.actions.length > 0 ? result.actions[0].lifecycle : "" })
    }
    return JSON.stringify(preview)
  }

  function enterNativeArgumentPreview(query) {
    var candidates = root.nativeRows(String(query || ""))
    if (candidates.length === 0) return "NoResult"
    var result = root.typedResultForCandidate(candidates[0])
    if (!result || result.actions.length === 0 || result.actions[0].arguments.length === 0)
      return "NoArguments"
    root.resetInteraction()
    root.activeResult = result
    root.chooseAction(result.actions[0])
    return root.interactionMode
  }

  function projectStatus() {
    return JSON.stringify({
      count: root.projects.length,
      workflows: root.validatedWorkflows.length,
      error: root.projectScanError,
      roots: root.configProjectRoots().length
    })
  }
  function projectCount() { return root.projects.length }
  function configuredWorkflowCount() { return root.validatedWorkflows.length }
  function scopedFileResultCount() {
    return root.projectScope ? root.fileRowsFromBatch(root.currentQuery()).length : 0
  }

  function enterProjectSearchByIdentity(identity) {
    var project = root.projectByIdentity(String(identity || ""))
    if (!project) return ""
    root.enterProjectSearch(project)
    return root.projectScope
  }

  function projectPreview(query) {
    var candidates = root.projectRows(String(query || ""))
    var preview = []
    for (var i = 0; i < candidates.length; i++) {
      var result = root.typedResultForCandidate(candidates[i])
      if (!result) continue
      var actions = []
      for (var j = 0; j < result.actions.length; j++) actions.push(result.actions[j].id)
      preview.push({ id: result.id, title: result.title, actions: actions })
    }
    return JSON.stringify(preview)
  }

  function workflowPreview(query) {
    var candidates = root.workflowRows(String(query || ""))
    var preview = []
    for (var i = 0; i < candidates.length; i++) {
      var result = root.typedResultForCandidate(candidates[i])
      if (!result) continue
      preview.push({ id: result.id, title: result.title,
        action: result.actions.length > 0 ? result.actions[0].id : "",
        projectValues: result.actions.length > 0 && result.actions[0].arguments.length > 0
          ? result.actions[0].arguments[0].values.length : 0 })
    }
    return JSON.stringify(preview)
  }

  function enterWorkflowArgumentPreview(query) {
    var candidates = root.workflowRows(String(query || ""))
    if (candidates.length === 0) return "NoResult"
    var result = root.typedResultForCandidate(candidates[0])
    if (!result || result.actions.length === 0) return "NoAction"
    root.resetInteraction()
    root.activeResult = result
    root.chooseAction(result.actions[0])
    return root.interactionMode
  }

  function workflowPlanPreview(identity) {
    var project = root.projectByIdentity(String(identity || ""))
    if (!project) return JSON.stringify({ ok: false, error: "Project not found" })
    var plan = Workflows.projectResume(project, { openRemote: false }, root.workflowCapabilities())
    if (!plan.ok) return JSON.stringify({ ok: false, error: plan.error })
    return JSON.stringify({
      ok: true,
      workflowId: plan.value.workflowId,
      projectId: plan.value.project.id,
      session: plan.value.steps.length > 1 ? plan.value.steps[1].session : "",
      steps: plan.value.steps.map(function(step) { return step.id })
    })
  }

  function hintFor(index) {
    var model = root.interactionMode === "Search" ? displayModel : actionModel
    if (index < 0 || index >= model.count) return ""
    return String(model.get(index).actionHint || "")
  }

  function disarmPointer() {
    pointerGate.reset()
  }


  function setInteractionQuery(value) {
    searchField.text = String(value || "")
    return root.currentQuery()
  }
  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function select(delta) {
    var count = root.activeModelCount()
    if (count === 0) return
    var step = Number(delta)
    if (!isFinite(step) || step === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = ((root.selectedIndex + step) % count + count) % count
    Qt.callLater(function() { root.revealCursor() })
  }

  function revealCursor() {
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function appendInteractionRow(object, icon, label, detail, hint, badge) {
    root.actionObjects.push(object)
    actionModel.append({
      resultId: String(object && object.id || "interaction:" + root.actionObjects.length),
      resultType: "action",
      source: root.activeResult ? root.activeResult.source : "system",
      sourceBadge: String(badge || ""),
      icon: String(icon || ""),
      iconFont: "",
      appIcon: "",
      label: String(label || ""),
      detail: String(detail || ""),
      actionHint: String(hint || "Enter"),
      section: ""
    })
  }

  function rebuildInteractionModel() {
    actionModel.clear()
    root.actionObjects = []
    var filter = root.currentQuery().toLowerCase()
    if (root.interactionMode === "Actions" && root.activeResult) {
      for (var i = 0; i < root.activeResult.actions.length; i++) {
        var action = root.activeResult.actions[i]
        if (filter && String(action.title).toLowerCase().indexOf(filter) < 0) continue
        var riskIcon = action.risk === "destructive" ? "󰀦" : (action.risk === "remote" ? "󰌘" : "󰐕")
        root.appendInteractionRow(action, riskIcon, action.title, action.subtitle || "",
          action.arguments.length > 0 ? "Enter to choose arguments" : (action.confirm ? "Enter to review" : "Enter"),
          action.risk === "safe" ? "" : action.risk)
      }
    } else if (root.interactionMode === "Arguments" && root.activeAction) {
      var field = root.activeAction.arguments[root.activeArgumentIndex]
      if (field) {
        if (field.values && field.values.length > 0) {
          for (var v = 0; v < field.values.length; v++) {
            var value = String(field.values[v])
            var valueLabel = value
            var valueDetail = field.title
            var valueIcon = "󰘧"
            if (field.type === "project") {
              var valueProject = root.projectByIdentity(value)
              if (valueProject) {
                valueLabel = valueProject.name
                valueDetail = root.shortPath(valueProject.path)
                valueIcon = "󰉋"
              }
            }
            if (filter && (valueLabel + " " + valueDetail).toLowerCase().indexOf(filter) < 0) continue
            root.appendInteractionRow({ id: "argument:" + root.stableHash(value), value: value },
              valueIcon, valueLabel, valueDetail, "Enter to select", field.type)
          }
        } else if (root.currentQuery()) {
          var typed = root.currentQuery()
          root.appendInteractionRow({ id: "argument:" + root.stableHash(typed), value: typed },
            "󰌑", "Use “" + typed + "”", field.title, "Enter to select", field.type)
        }
      }
    } else if (root.interactionMode === "Confirm" && root.activeAction) {
      var confirmDetail = root.activeResult ? root.activeResult.title : ""
      if (root.pendingWorkflowPlan && root.pendingWorkflowPlan.steps)
        confirmDetail = root.pendingWorkflowPlan.steps.map(function(step) { return step.title }).join(" → ")
      root.appendInteractionRow({ id: "confirm:" + root.activeAction.id, confirm: true },
        "󰀦", "Confirm " + root.activeAction.title,
        confirmDetail, "Enter confirms · Escape cancels", root.activeAction.risk)
    } else if (root.interactionMode === "Running") {
      root.appendInteractionRow({ id: "running:" + root.actionRunToken },
        "󰑮", root.actionMessage || "Running", root.actionDetail, "Escape cancels", "running")
    } else if (root.interactionMode === "Result") {
      root.appendInteractionRow({ id: "result:" + root.actionRunToken },
        root.actionSucceeded ? "󰄬" : "󰅙", root.actionMessage || "Done", root.actionDetail,
        "Escape returns", root.actionSucceeded ? "success" : "error")
    }
    layoutSerial += 1
    if (actionModel.count === 0) root.selectedIndex = 0
    else root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, actionModel.count - 1))
    Qt.callLater(function() { if (actionModel.count > 0) root.revealCursor() })
  }

  function applyFlowResult(result) {
    if (!result || !result.ok) return false
    root.flowState = result.value
    var frame = Flow.current(root.flowState)
    root.interactionMode = frame.ok ? frame.value.mode : "Search"
    return true
  }

  function enterActions(index) {
    var result = root.activeObject(index)
    if (!result || !result.actions || result.actions.length === 0) return
    root.searchSelectedIndex = index
    var queryState = Flow.setQuery(root.flowState, searchField.text)
    if (queryState.ok) root.flowState = queryState.value
    var pushed = Flow.push(root.flowState, "Actions", result.title, { resultId: result.id })
    if (!root.applyFlowResult(pushed)) return
    root.activeResult = result
    root.activeAction = null
    root.selectedIndex = 0
    searchField.text = ""
    root.rebuildInteractionModel()
  }

  function enterArguments(action) {
    root.activeAction = action
    root.activeArgumentIndex = 0
    root.argumentValues = ({})
    var pushed = Flow.push(root.flowState, "Arguments", action.title, { actionId: action.id })
    if (!root.applyFlowResult(pushed)) return
    root.selectedIndex = 0
    searchField.text = ""
    root.rebuildInteractionModel()
  }

  function enterConfirm(action) {
    root.activeAction = action
    if (action.executor === "workflow") {
      var workflowPlan = root.planWorkflowAction(action)
      root.pendingWorkflowPlan = workflowPlan.ok ? workflowPlan.value : null
    }
    var pushed = Flow.push(root.flowState, "Confirm", action.title, { actionId: action.id })
    if (!root.applyFlowResult(pushed)) return
    root.selectedIndex = 0
    searchField.text = ""
    root.rebuildInteractionModel()
  }

  function returnInteraction() {
    if (root.interactionMode === "Confirm") root.pendingWorkflowPlan = null
    if (root.interactionMode === "Search") return false
    if (root.interactionMode === "Running") {
      root.cancelRunningAction()
      return true
    }
    var popped = Flow.pop(root.flowState)
    if (!root.applyFlowResult(popped)) return true
    root.selectedIndex = 0
    if (root.interactionMode === "Search") {
      var frame = Flow.current(root.flowState)
      root.selectedIndex = root.searchSelectedIndex
      searchField.text = frame.ok ? frame.value.query : ""
      root.rebuildDisplay(true)
    } else {
      searchField.text = ""
      root.rebuildInteractionModel()
    }
    return true
  }

  function enterProjectSearch(project) {
    var checked = Workflows.validateProject(project)
    if (!checked.ok) return
    root.resetInteraction()
    root.projectScope = checked.value.path
    root.projectScopeTitle = checked.value.name
    root.selectedIndex = 0
    root.fileRows = []
    searchField.text = ""
    root.rebuildDisplay(false)
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function leaveProjectScope() {
    root.projectScope = ""
    root.projectScopeTitle = ""
    root.fileRows = []
    root.querySerial += 1
    searchField.text = ""
    root.rebuildDisplay(false)
  }

  function handleArgumentSelection(index) {
    var choice = root.activeObject(index)
    var field = root.activeAction && root.activeAction.arguments[root.activeArgumentIndex]
    if (!choice || !field) return
    root.argumentValues[field.id] = choice.value
    root.activeArgumentIndex += 1
    if (root.activeArgumentIndex < root.activeAction.arguments.length) {
      root.selectedIndex = 0
      searchField.text = ""
      root.rebuildInteractionModel()
      return
    }
    if (Execution.requiresConfirmation(root.activeAction)) root.enterConfirm(root.activeAction)
    else root.runAction(root.activeAction)
  }

  function actionArgv(action) {
    return Execution.argvFor(action)
  }

  function recordTypedUsage(result, action) {
    if (!result || !action || !root.learnableResultType(result.type)) return
    var persistedValue = result.value.payload
    if (result.source === "projects") {
      try { persistedValue = String(JSON.parse(String(persistedValue)).path || "") }
      catch (_projectUsageError) { return }
      if (root.usageKey("projects", persistedValue) !== result.id) return
    } else if (result.source === "workflows") {
      try { persistedValue = String(JSON.parse(String(persistedValue)).id || "") }
      catch (_workflowUsageError) { return }
      if (root.usageKey("workflows", persistedValue) !== result.id) return
    }
    if (result.source === "native") {
      try {
        var nativeUsageSpec = JSON.parse(String(persistedValue))
        if (nativeUsageSpec.learnable !== true) return
        persistedValue = String(nativeUsageSpec.route || "")
      } catch (_nativeUsageError) { return }
      if (root.usageKey("native", persistedValue) !== result.id) return
    }
    var entry = root.usage[result.id] || ({ count: 0, result: ({}) })
    entry.count = (Number(entry.count) || 0) + 1
    entry.lastUsed = Date.now()
    entry.actionId = action.id
    entry.result = {
      id: result.id,
      source: result.source,
      type: result.type,
      icon: result.icon,
      appIcon: result.appIcon,
      title: result.title,
      subtitle: result.subtitle,
      value: persistedValue
    }
    root.usage[result.id] = entry
    root.saveUsage()
  }

  function showImmediateResult(ok, message, detail) {
    var finished = ok
      ? Flow.succeed(root.flowState, root.actionRunToken, message, {})
      : Flow.fail(root.flowState, root.actionRunToken, message, {})
    if (finished.ok) root.flowState = finished.value
    root.interactionMode = "Result"
    root.actionMessage = message
    root.actionSucceeded = ok
    root.actionDetail = String(detail || "")
    root.rebuildInteractionModel()
  }

  function executeNativeArgv(action, argv) {
    if (action.lifecycle === "keepOpen") root.startCapturedAction(argv, false)
    else {
      root.cancel()
      Util.execArgv(Execution.argvFor({
        argv: argv,
        lifecycle: action.lifecycle,
        risk: action.risk
      }))
    }
  }

  function executeBuiltin(action) {
    var result = root.activeResult
    var payload = result && result.value ? String(result.value.payload || "") : ""
    if (action.builtin === "projectSearch"
        || action.builtin === "projectCopyPath"
        || action.builtin === "projectTerminal") {
      var projectInput
      try { projectInput = JSON.parse(payload) } catch (_projectActionError) {
        root.showImmediateResult(false, "Invalid project metadata", "")
        return
      }
      var checkedProject = Workflows.validateProject(projectInput)
      if (!checkedProject.ok) {
        root.showImmediateResult(false, "Invalid project metadata", checkedProject.error)
        return
      }
      var actionProject = checkedProject.value
      if (action.builtin === "projectSearch") {
        root.enterProjectSearch(actionProject)
        return
      }
      if (action.builtin === "projectCopyPath") {
        Util.execArgv([root.omarchyPath + "/bin/omarchy-clipboard-paste-text",
          "--copy-only", actionProject.path])
        root.showImmediateResult(true, "Copied project path", actionProject.path)
        return
      }
      root.cancel()
      if (root.focusProjectWindow(actionProject, true)) return
      var session = Workflows.sessionName(actionProject)
      if (root.nativeStates.tmux === "available")
        Util.execArgv(["xdg-terminal-exec", "--title=" + session, "--",
          "tmux", "new-session", "-A", "-s", session, "-c", actionProject.path])
      else
        Util.execArgv(["xdg-terminal-exec", "--title=" + actionProject.name,
          "--dir=" + actionProject.path])
      return
    }
    if (action.builtin === "reloadNativeCatalog") {
      root.loadNativeCatalog(true)
      root.showImmediateResult(true, "Reloading command catalog", root.nativeCatalogError)
      return
    }
    if (action.builtin === "inspectNativeCommand") {
      var inspectSpec
      try { inspectSpec = JSON.parse(payload) } catch (_inspectError) { inspectSpec = ({}) }
      var inspectLines = [
        String(inspectSpec.route || "Unknown route"),
        String(inspectSpec.args || ""),
        String(inspectSpec.provenance || "")
      ]
      if (inspectSpec.examples && inspectSpec.examples.length > 0)
        inspectLines.push("Example: " + inspectSpec.examples[0])
      root.showImmediateResult(true, result.title, inspectLines.filter(function(line) { return !!line }).join("\n"))
      return
    }
    if (action.builtin === "runNativeTemplate") {
      var templateSpec
      try { templateSpec = JSON.parse(payload) } catch (_templateError) {
        root.showImmediateResult(false, "Invalid command metadata", "")
        return
      }
      var templateArgv = (templateSpec.argv || []).slice()
      var order = templateSpec.argumentOrder || []
      for (var templateIndex = 0; templateIndex < order.length; templateIndex++) {
        var argumentId = order[templateIndex]
        var templateValue = String(root.argumentValues[argumentId] || "")
        if (!templateValue) {
          root.showImmediateResult(false, "Missing option", argumentId)
          return
        }
        var valueMap = templateSpec.argumentValueMap && templateSpec.argumentValueMap[argumentId]
        var resolvedValue = valueMap && Object.prototype.hasOwnProperty.call(valueMap, templateValue)
          ? String(valueMap[templateValue]) : templateValue
        if (resolvedValue) templateArgv.push(resolvedValue)
      }
      root.executeNativeArgv(action, templateArgv)
      return
    }
    if (action.builtin === "runNativeWithArguments") {
      var runSpec
      try { runSpec = JSON.parse(payload) } catch (_runError) {
        root.showImmediateResult(false, "Invalid command metadata", "")
        return
      }
      var parsedArguments = Native.parseWords(String(root.argumentValues.arguments || ""))
      if (!parsedArguments.ok || parsedArguments.value.length === 0) {
        root.showImmediateResult(false, "Invalid arguments", parsedArguments.error || "Arguments are required")
        return
      }
      var nativeArgv = (runSpec.argv || []).concat(parsedArguments.value)
      root.executeNativeArgv(action, nativeArgv)
      return
    }
    if (action.builtin === "inspectLearning") {
      var learnedKeys = []
      for (var learnedKey in root.usage) learnedKeys.push(learnedKey)
      learnedKeys.sort()
      var summary = []
      for (var learnedIndex = 0; learnedIndex < Math.min(learnedKeys.length, 12); learnedIndex++) {
        var learnedEntry = root.usage[learnedKeys[learnedIndex]] || ({})
        summary.push(learnedKeys[learnedIndex]
          + (learnedEntry.pinned ? " · pinned" : "")
          + (learnedEntry.alias ? " · alias " + learnedEntry.alias : "")
          + (learnedEntry.actionId ? " · " + learnedEntry.actionId : ""))
      }
      root.showImmediateResult(true, learnedKeys.length + " learned targets", summary.join("\n"))
      return
    }
    if (action.builtin === "resetLearning") {
      root.usage = ({})
      root.saveUsage()
      root.showImmediateResult(true, "Omnibox learning reset", "")
      return
    }

    if (action.builtin === "togglePin") {
      var entry = root.usage[result.id] || ({ count: 0, lastUsed: 0, result: ({}) })
      entry.pinned = !entry.pinned
      root.usage[result.id] = entry
      root.saveUsage()
      root.showImmediateResult(true, entry.pinned ? "Pinned " + result.title : "Unpinned " + result.title, "")
      return
    }
    if (action.builtin === "forgetUsage") {
      delete root.usage[result.id]
      root.saveUsage()
      root.showImmediateResult(true, "Forgot " + result.title, "")
      return
    }
    if (action.builtin === "setAlias") {
      var alias = String(root.argumentValues.alias || "").trim()
      if (!alias) {
        root.showImmediateResult(false, "Alias was empty", "Enter a non-empty alias")
        return
      }
      var aliasEntry = root.usage[result.id] || ({ count: 0, lastUsed: 0, result: ({}) })
      aliasEntry.alias = alias.slice(0, 80)
      root.usage[result.id] = aliasEntry
      root.saveUsage()
      root.showImmediateResult(true, "Alias set to “" + aliasEntry.alias + "”", "")
      return
    }

    var closeFirst = action.lifecycle !== "keepOpen"
    if (closeFirst) root.cancel()
    if (action.builtin === "appOpen") {
      if (root.appLibrary) root.appLibrary.launch(payload, result.title)
    } else if (action.builtin === "windowFocus") {
      Util.execArgv(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:' + payload + '" })'])
    } else if (action.builtin === "windowMoveWorkspace") {
      var workspace = String(root.argumentValues.workspace || "")
      Util.execArgv(["hyprctl", "dispatch",
        'hl.dsp.window.move({ workspace = "' + workspace + '", window = "address:' + payload + '" })'])
    } else if (action.builtin === "windowMoveMonitor") {
      var monitor = String(root.argumentValues.monitor || "")
      Util.execArgv(["hyprctl", "dispatch",
        'hl.dsp.window.move({ monitor = "' + monitor + '", window = "address:' + payload + '" })'])
    } else if (action.builtin === "windowFloat") {
      Util.execArgv(["hyprctl", "dispatch", 'hl.dsp.window.float({ window = "address:' + payload + '" })'])
    } else if (action.builtin === "windowClose") {
      Util.execArgv(["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "address:' + payload + '" })'])
    } else if (action.builtin === "fileReveal") {
      var slash = payload.lastIndexOf("/")
      Util.execArgv(["xdg-open", slash > 0 ? payload.slice(0, slash) : payload])
    } else if (action.builtin === "fileTerminal") {
      var directorySlash = payload.lastIndexOf("/")
      var directory = directorySlash > 0 ? payload.slice(0, directorySlash) : payload
      Util.execArgv(["xdg-terminal-exec", "--dir=" + directory])
    } else if (action.builtin === "copyValue") {
      Util.execArgv([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--copy-only", payload])
    } else if (action.builtin === "pasteValue") {
      Util.execArgv([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--shift-insert", payload])
    } else if (action.builtin === "copyIdentity") {
      var identity = result.id.indexOf("ssh:") === 0 ? result.id.slice(4) : payload
      Util.execArgv([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--copy-only", identity])
    } else if (action.builtin === "clipboardImageCopy") {
      var imageParts = payload.split("\u0000")
      if (imageParts.length === 2)
        Util.execArgv([root.omarchyPath + "/bin/omarchy-clipboard-paste-file", "--copy-only", imageParts[0], imageParts[1]])
    } else if (action.builtin === "clipboardPaste") {
      Util.execArgv([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--shift-insert", "--history-index", payload])
    } else if (action.builtin === "clipboardCopy") {
      Util.execArgv([root.omarchyPath + "/bin/omarchy-clipboard-paste-text", "--copy-only", "--history-index", payload])
    }
    if (!closeFirst) root.showImmediateResult(true, action.title + " complete", "")
  }

  function runAction(action) {
    if (!root.activeResult || !action) return
    root.activeAction = action
    var started = Flow.begin(root.flowState, action.title, { actionId: action.id })
    if (!started.ok) return
    root.flowState = started.value.state
    root.actionRunToken = started.value.token
    root.interactionMode = "Running"
    root.actionMessage = action.title
    root.actionDetail = ""
    root.recordTypedUsage(root.activeResult, action)
    root.rebuildInteractionModel()

    if (action.executor === "builtin") {
      root.executeBuiltin(action)
      return
    }
    if (action.executor === "argv") {
      var argv = root.actionArgv(action)
      if (action.lifecycle === "keepOpen") {
        root.startCapturedAction(argv, false)
      } else {
        root.cancel()
        Util.execArgv(argv)
      }
      return
    }
    if (action.executor === "workflow") {
      root.startWorkflowAction(action)
      return
    }
    if (action.executor === "shell" && action.trusted) {
      if (action.lifecycle === "keepOpen") root.startCapturedAction(["bash", "-lc", action.command], true)
      else {
        var command = action.command
        root.cancel()
        Util.execDetached(command)
      }
      return
    }
    root.showImmediateResult(false, "Unsupported action", action.executor)
  }

  function chooseAction(action) {
    if (!action) return
    if (action.arguments && action.arguments.length > 0) {
      root.enterArguments(action)
      return
    }
    if (Execution.requiresConfirmation(action)) {
      root.enterConfirm(action)
      return
    }
    root.runAction(action)
  }

  function activateIndex(index, modifiers) {
    if (root.interactionMode === "Search") {
      var result = root.activeObject(index)
      if (!result) return
      root.activeResult = result
      root.searchSelectedIndex = index
      var action = result.actions[0]
      if ((modifiers & Qt.AltModifier) && result.type === "file") {
        for (var i = 0; i < result.actions.length; i++)
          if (result.actions[i].id === "file.reveal") action = result.actions[i]
      }
      root.chooseAction(action)
      return
    }
    if (root.interactionMode === "Actions") {
      root.chooseAction(root.activeObject(index))
      return
    }
    if (root.interactionMode === "Arguments") {
      root.handleArgumentSelection(index)
      return
    }
    if (root.interactionMode === "Confirm") {
      root.runAction(root.activeAction)
      return
    }
  }

  function activateCurrent(modifiers) {
    if (root.activeModelCount() === 0) return
    root.activateIndex(root.cursorActive ? root.selectedIndex : 0, modifiers || Qt.NoModifier)
  }

  function activateAt(index) {
    root.activateIndex(Number(index), Qt.NoModifier)
    return root.interactionMode
  }

  function workflowById(id) {
    for (var i = 0; i < root.validatedWorkflows.length; i++)
      if (root.validatedWorkflows[i].id === id) return root.validatedWorkflows[i]
    return null
  }

  function workflowCapabilities() {
    return {
      terminal: true,
      tmux: root.nativeStates.tmux === "available",
      browser: true
    }
  }

  function workflowStatusText(runtime) {
    if (!runtime || !runtime.statuses) return ""
    var lines = []
    for (var i = 0; i < runtime.statuses.length; i++) {
      var status = runtime.statuses[i]
      var title = runtime.plan.steps[i].title
      lines.push((status.state === "success" ? "✓ "
        : (status.state === "failure" ? "✕ "
          : (status.state === "optional-failure" ? "⚠ " : "· "))) + title)
    }
    return lines.join("\n")
  }

  function planWorkflowAction(action) {
    if (!action) return { ok: false, error: "Workflow action missing" }
    if (action.workflowId === "project.resume") {
      var projectInput
      try { projectInput = JSON.parse(String(root.activeResult.value.payload || "")) }
      catch (_resumeError) { return { ok: false, error: "Invalid project metadata" } }
      return Workflows.projectResume(projectInput, {
        openRemote: root.config.projects && root.config.projects.openRemote === true
      }, root.workflowCapabilities())
    }
    var workflow = root.workflowById(action.workflowId)
    var project = root.projectByIdentity(root.argumentValues.project)
    if (!workflow || !project) return { ok: false, error: "Workflow inputs unavailable" }
    return Workflows.buildPlan(workflow, { project: project.id },
      root.projects, root.workflowCapabilities())
  }

  function startWorkflowAction(action) {
    var planned = root.pendingWorkflowPlan
      && root.pendingWorkflowPlan.workflowId === action.workflowId
      ? { ok: true, value: root.pendingWorkflowPlan }
      : root.planWorkflowAction(action)
    root.pendingWorkflowPlan = null
    if (!planned || !planned.ok) {
      root.showImmediateResult(false, "Workflow plan rejected", planned && planned.error || "")
      return
    }
    var started = Workflows.start(planned.value, root.actionRunToken)
    if (!started.ok) {
      root.showImmediateResult(false, "Workflow could not start", started.error)
      return
    }
    root.workflowPlan = planned.value
    root.workflowRuntime = started.value
    root.workflowRunToken = root.actionRunToken
    root.executeWorkflowStep()
  }

  function startWorkflowProcess(argv) {
    workflowProc.latestRun += 1
    workflowProc.activeRun = workflowProc.latestRun
    workflowProc.activeToken = root.workflowRunToken
    workflowProc.stdoutText = ""
    workflowProc.stderrText = ""
    workflowProc.command = argv
    workflowProc.running = true
    workflowTimeout.restart()
  }

  function executeWorkflowStep() {
    if (!root.workflowRuntime || root.workflowRuntime.done) return
    var current = Workflows.current(root.workflowRuntime)
    if (!current.ok || !current.value) {
      root.showImmediateResult(false, "Workflow state invalid", current.error || "")
      return
    }
    var step = current.value
    var index = root.workflowRuntime.index
    root.actionMessage = root.workflowPlan.title + " · " + (index + 1) + "/" + root.workflowPlan.steps.length
    root.actionDetail = root.workflowStatusText(root.workflowRuntime)
    root.rebuildInteractionModel()

    if (step.executor === "builtin" && step.builtin === "projectEditor") {
      if (root.focusProjectWindow(step.project, false)) {
        root.advanceWorkflow(true, "Focused existing editor")
        return
      }
      Util.execArgv(["omarchy", "launch", "editor", step.project.path])
      root.advanceWorkflow(true, "Launched editor")
      return
    }
    if (step.executor === "builtin" && step.builtin === "projectTerminal") {
      if (root.focusProjectWindow(step.project, true)) {
        root.advanceWorkflow(true, "Focused existing terminal")
        return
      }
      if (step.tmux) {
        Util.execArgv(["xdg-terminal-exec", "--title=" + step.session, "--",
          "tmux", "new-session", "-A", "-s", step.session, "-c", step.project.path])
      } else {
        Util.execArgv(["xdg-terminal-exec", "--title=" + step.project.name,
          "--dir=" + step.project.path])
      }
      root.advanceWorkflow(true, "Launched terminal")
      return
    }
    if (step.executor === "argv") {
      root.startWorkflowProcess(step.argv)
      return
    }
    root.advanceWorkflow(false, "Unsupported workflow step")
  }

  function advanceWorkflow(ok, detail) {
    if (!root.workflowRuntime) return
    var advanced = ok
      ? Workflows.succeedStep(root.workflowRuntime, root.workflowRunToken, detail)
      : Workflows.failStep(root.workflowRuntime, root.workflowRunToken, detail)
    if (!advanced.ok) return
    root.workflowRuntime = advanced.value
    if (root.workflowRuntime.done) {
      var success = !root.workflowRuntime.failed && !root.workflowRuntime.canceled
      root.showImmediateResult(success,
        root.workflowPlan.title + (success ? " complete" : " failed"),
        root.workflowStatusText(root.workflowRuntime))
      return
    }
    Qt.callLater(function() { root.executeWorkflowStep() })
  }

  function formatCapturedDetail(ok, stdoutText, stderrText, exitCode) {
    if (!ok) return String(stderrText || "").trim() || "Exit " + exitCode
    var output = String(stdoutText || "").trim()
    if (root.activeResult && root.activeResult.source === "native") {
      try {
        var spec = JSON.parse(String(root.activeResult.value.payload || "{}"))
        if (spec.outputFormat === "reminders") {
          var parsed = JSON.parse(output || "{}")
          var reminders = parsed.reminders || []
          if (reminders.length === 0) return "No active reminders"
          var lines = []
          for (var i = 0; i < Math.min(reminders.length, 8); i++)
            lines.push(String(reminders[i].label || "Reminder") + " · " + String(reminders[i].remaining || ""))
          return lines.join("\n")
        }
      } catch (_formatError) { }
    }
    return output
  }

  function startCapturedAction(argv, _shellAction) {
    if (!Array.isArray(argv) || argv.length === 0) {
      root.showImmediateResult(false, "Action had no command", "")
      return
    }
    actionProc.latestRun += 1
    actionProc.activeRun = actionProc.latestRun
    actionProc.activeToken = root.actionRunToken
    actionProc.stdoutText = ""
    actionProc.stderrText = ""
    actionProc.command = argv
    actionProc.running = true
    actionTimeoutTimer.restart()
  }

  function runHealthCheck() {
    var result = Actions.makeResult({
      id: "diagnostic:health",
      type: "diagnostic",
      source: "system",
      title: "Omnibox health check",
      subtitle: "Read installed Omarchy version",
      value: { payload: "" },
      actions: [{
        id: "diagnostic.health",
        title: "Health check",
        executor: "argv",
        argv: ["omarchy", "version"],
        lifecycle: "keepOpen",
        risk: "safe"
      }]
    })
    if (!result.ok) return "invalid"
    root.resetInteraction()
    root.activeResult = result.value
    root.runAction(result.value.actions[0])
    return root.interactionMode
  }

  function cancelRunningAction() {
    actionTimeoutTimer.stop()
    actionProc.latestRun += 1
    if (actionProc.running) actionProc.running = false
    workflowTimeout.stop()
    workflowProc.latestRun += 1
    if (workflowProc.running) workflowProc.running = false
    if (root.workflowRuntime) {
      var workflowCanceled = Workflows.cancel(root.workflowRuntime, root.workflowRunToken)
      if (workflowCanceled.ok) root.workflowRuntime = workflowCanceled.value
    }
    var canceled = Flow.cancel(root.flowState, root.actionRunToken)
    if (canceled.ok) root.flowState = canceled.value
    root.interactionMode = "Result"
    root.actionMessage = "Canceled"
    root.actionSucceeded = false
    root.actionDetail = root.workflowRuntime ? root.workflowStatusText(root.workflowRuntime) : ""
    root.rebuildInteractionModel()
  }

  function timeoutRunningAction() {
    actionProc.latestRun += 1
    if (actionProc.running) actionProc.running = false
    var timedOut = Flow.fail(root.flowState, root.actionRunToken, "Timed out", {})
    if (timedOut.ok) root.flowState = timedOut.value
    root.interactionMode = "Result"
    root.actionMessage = "Action timed out"
    root.actionSucceeded = false
    root.actionDetail = "Exceeded 15 seconds"
    root.rebuildInteractionModel()
  }

  Timer {
    id: actionTimeoutTimer
    interval: 15000
    repeat: false
    onTriggered: root.timeoutRunningAction()
  }

  Process {
    id: actionProc
    property int latestRun: 0
    property int activeRun: 0
    property string activeToken: ""
    property string stdoutText: ""
    property string stderrText: ""
    stdout: SplitParser {
      onRead: function(data) {
        actionProc.stdoutText = Execution.boundedAppend(
          actionProc.stdoutText, data + "\n", root.maxActionOutputBytes)
      }
    }
    stderr: SplitParser {
      onRead: function(data) {
        actionProc.stderrText = Execution.boundedAppend(
          actionProc.stderrText, data + "\n", root.maxActionOutputBytes)
      }
    }
    onExited: function(exitCode, exitStatus) {
      actionTimeoutTimer.stop()
      if (actionProc.activeRun !== actionProc.latestRun
          || actionProc.activeToken !== root.actionRunToken
          || root.interactionMode !== "Running") return
      var ok = exitCode === 0 && exitStatus === 0
      var detail = root.formatCapturedDetail(
        ok, actionProc.stdoutText, actionProc.stderrText, exitCode)
      root.showImmediateResult(ok, ok ? root.activeAction.title + " complete" : root.activeAction.title + " failed", detail)
    }
  }

  Process {
    id: workflowProc
    property int latestRun: 0
    property int activeRun: 0
    property string activeToken: ""
    property string stdoutText: ""
    property string stderrText: ""
    stdout: SplitParser {
      onRead: function(data) {
        workflowProc.stdoutText = Execution.boundedAppend(
          workflowProc.stdoutText, data + "\n", root.maxActionOutputBytes)
      }
    }
    stderr: SplitParser {
      onRead: function(data) {
        workflowProc.stderrText = Execution.boundedAppend(
          workflowProc.stderrText, data + "\n", root.maxActionOutputBytes)
      }
    }
    onExited: function(exitCode, exitStatus) {
      workflowTimeout.stop()
      if (workflowProc.activeRun !== workflowProc.latestRun
          || workflowProc.activeToken !== root.workflowRunToken
          || !root.workflowRuntime) return
      var ok = exitCode === 0 && exitStatus === 0
      root.advanceWorkflow(ok, ok ? workflowProc.stdoutText.trim()
        : (workflowProc.stderrText.trim() || "Exit " + exitCode))
    }
  }

  Timer {
    id: workflowTimeout
    interval: 15000
    repeat: false
    onTriggered: {
      workflowProc.latestRun += 1
      if (workflowProc.running) workflowProc.running = false
      root.advanceWorkflow(false, "Step exceeded 15 seconds")
    }
  }


  FileView {
    id: projectCacheView
    path: root.projectsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadProjects(text())
    onFileChanged: reload()
  }

  Process {
    id: projectScanProc
    property int latestRun: 0
    property int activeRun: 0
    property var projects: []
    stdout: SplitParser {
      onRead: function(data) {
        if (projectScanProc.activeRun !== projectScanProc.latestRun
            || projectScanProc.projects.length >= root.configProjectLimit()) return
        try {
          var input = JSON.parse(String(data || ""))
          input.id = Workflows.projectId(String(input.path || ""))
          var checked = Workflows.validateProject(input)
          if (checked.ok) {
            var next = projectScanProc.projects.slice()
            next.push(checked.value)
            projectScanProc.projects = next
          }
        } catch (_projectLineError) { }
      }
    }
    onExited: function(exitCode, exitStatus) {
      projectScanTimeout.stop()
      if (projectScanProc.activeRun !== projectScanProc.latestRun) return
      if (exitCode !== 0 || exitStatus !== 0) {
        root.projectScanError = "Project scan exited " + exitCode
        return
      }
      root.publishProjects(projectScanProc.projects)
    }
  }

  Timer {
    id: projectScanTimeout
    interval: 4000
    repeat: false
    onTriggered: {
      projectScanProc.latestRun += 1
      if (projectScanProc.running) projectScanProc.running = false
      root.projectScanError = "Project scan exceeded 4 seconds"
    }
  }

  Process {
    id: projectWriterProc
    property string payload: ""
    property bool pending: false
    stdinEnabled: true
    onStarted: write(payload + "\n")
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0)
        console.warn("omnibox: project cache write failed:", exitCode, exitStatus)
      if (projectWriterProc.pending) {
        projectWriterProc.pending = false
        Qt.callLater(function() { root.saveProjects() })
      }
    }
  }

  Process {
    id: projectWatchProc
    stdout: SplitParser { onRead: function(_data) { projectRefreshTimer.restart() } }
    onRunningChanged: {
      if (!running && root.configProjectRoots().length > 0) projectWatchRestartTimer.restart()
    }
  }

  Timer {
    id: projectRefreshTimer
    interval: 250
    repeat: false
    onTriggered: root.runProjectScan()
  }

  Timer {
    id: projectWatchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: root.startProjectWatcher(false)
  }

  Process {
    id: nativeCatalogProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) {
        nativeCatalogProc.collected = Execution.boundedAppend(
          nativeCatalogProc.collected, data + "\n", root.maxNativeCatalogBytes)
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) {
        root.nativeCatalogError = "Catalog exited " + exitCode
        return
      }
      var parsed = Native.parseCatalog(nativeCatalogProc.collected)
      if (!parsed.ok) {
        root.nativeCatalogError = parsed.error
        return
      }
      root.nativeCommands = parsed.value
      root.nativeCatalogLoaded = true
      root.nativeCatalogError = ""
      if (root.opened && root.interactionMode === "Search") root.rebuildDisplay(true)
    }
  }

  Process {
    id: nativeThemesProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) {
        nativeThemesProc.collected = Execution.boundedAppend(
          nativeThemesProc.collected, data + "\n", 65536)
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) return
      var lines = nativeThemesProc.collected.split("\n")
      var themes = []
      var seen = ({})
      for (var i = 0; i < lines.length && themes.length < 256; i++) {
        var theme = String(lines[i] || "").trim()
        if (theme && !seen[theme]) {
          seen[theme] = true
          themes.push(theme)
        }
      }
      if (themes.length > 0) root.nativeThemes = themes
      if (root.opened && root.interactionMode === "Search") root.rebuildDisplay(true)
    }
  }

  Process {
    id: nativeStateProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) {
        nativeStateProc.collected = Execution.boundedAppend(
          nativeStateProc.collected, data + "\n", 16384)
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) return
      var next = ({})
      for (var key in root.nativeStates) next[key] = root.nativeStates[key]
      var lines = nativeStateProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var tab = lines[i].indexOf("\t")
        if (tab <= 0) continue
        var stateKey = lines[i].slice(0, tab)
        var stateValue = lines[i].slice(tab + 1, tab + 257)
        if (/^[a-z0-9-]+$/.test(stateKey) && stateValue) next[stateKey] = stateValue
      }
      root.nativeStates = next
      if (root.opened && root.interactionMode === "Search") root.rebuildDisplay(true)
    }
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
      if (root.opened && !root.projectScope) root.runProviders(root.currentQuery())
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
      if (!root.projectScope) root.runProviders(query)
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
    root.buildSourceRegistry()
    root.configureProjects()
    root.loadNativeCatalog(false)
    root.loadNativeThemes(false)
    root.refreshNativeState()
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
  readonly property bool breadcrumbVisible: root.interactionBreadcrumb().length > 0
  readonly property int breadcrumbHeight: root.breadcrumbVisible ? root.sectionHeight : 0
  property int sectionHeight: Style.space(18)
  property int maxRowsHeight: Style.space(420)
  property int layoutSerial: 0

  readonly property int cardWidth: Math.min(Style.space(460), Math.max(1, panel.width - Style.gapsOut * 2))
  readonly property int minimumCardHeight: root.cardBorderHeight + root.contentMargin * 2
    + root.inputHeight + root.breadcrumbHeight
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
    var extra = root.breadcrumbVisible ? root.breadcrumbHeight + root.contentSpacing() : 0
    var available = panel.height - root.cardTop - Style.gapsOut - root.cardBorderHeight
      - root.contentMargin * 2 - root.inputHeight - extra - root.contentSpacing()
    return Math.max(0, available)
  }

  function contentSpacing() { return Style.spacing.md }

  function naturalRowsHeight(_serial) {
    var model = root.interactionMode === "Search" ? displayModel : actionModel
    if (model.count === 0) return root.baseRowHeight
    var total = 0
    for (var i = 0; i < model.count; i++) {
      var row = model.get(i)
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
    + root.inputHeight + (root.breadcrumbVisible ? root.breadcrumbHeight + root.contentSpacing() : 0)
    + root.contentSpacing() + root.rowsHeight(layoutSerial)

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "bitr0t-omnibox"
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
            text: root.interactionMode === "Search" ? "󰈉" : (root.interactionMode === "Confirm" ? "󰀦" : "󰐕")
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
            placeholderText: root.interactionMode === "Search" ? "Apps, files, math, web…"
              : (root.interactionMode === "Actions" ? "Filter actions…"
                : (root.interactionMode === "Arguments" ? "Type or choose a value…" : ""))
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
              var shift = !!(event.modifiers & Qt.ShiftModifier)
              var control = !!(event.modifiers & Qt.ControlModifier)
              if (event.key === Qt.Key_Escape) {
                if (root.interactionMode !== "Search") root.returnInteraction()
                else if (searchField.text) searchField.text = ""
                else if (root.projectScope) root.leaveProjectScope()
                else root.cancel()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab && shift) {
                if (root.interactionMode !== "Search") root.returnInteraction()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || (control && event.key === Qt.Key_K)) {
                if (root.interactionMode === "Search")
                  root.enterActions(root.cursorActive ? root.selectedIndex : 0)
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

        Text {
          width: parent.width
          height: root.breadcrumbHeight
          visible: root.breadcrumbVisible
          text: root.interactionBreadcrumb()
          color: root.foreground
          opacity: 0.72
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.weight: Font.DemiBold
          elide: Text.ElideMiddle
          verticalAlignment: Text.AlignVCenter
        }

        Item {
          width: parent.width
          height: root.rowsHeight(layoutSerial)

          ListView {
            id: resultList
            anchors.fill: parent
            model: root.interactionMode === "Search" ? displayModel : actionModel
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
              required property string resultId
              required property string resultType
              required property string source
              required property string sourceBadge
              required property string icon
              required property string iconFont
              required property string appIcon
              required property string label
              required property string detail
              required property string actionHint

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
                anchors.rightMargin: row.sourceBadge.length > 0 ? Style.space(86) : Style.spacing.xl
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

              Text {
                visible: row.sourceBadge.length > 0
                text: row.sourceBadge.toUpperCase()
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: row.hasCursor ? 0.9 : 0.58
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                width: Style.space(72)
                horizontalAlignment: Text.AlignRight
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
            visible: root.activeModelCount() === 0
              && (root.currentQuery() || root.interactionMode === "Arguments" || root.interactionMode === "Actions")

            Text {
              text: root.interactionMode === "Arguments" ? "󰌑" : "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }

            Text {
              text: root.interactionMode === "Arguments" && !root.currentQuery()
                ? "Type a value to continue"
                : (root.interactionMode === "Actions" ? "No matching actions"
                  : "No matches for “" + root.currentQuery() + "”")
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

// Omarchy command catalog, conservative policy, and deterministic typed intents.

var NATIVE_MAX_COMMANDS = 2000;
var NATIVE_MAX_FIELD_BYTES = 16384;

function nativeOk(value) { return { ok: true, value: value }; }
function nativeError(message) { return { ok: false, error: String(message || "Native command error").slice(0, 512) }; }

function nativeBytes(value) {
    var text = String(value);
    var bytes = 0;
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i);
        if (code < 128) bytes += 1;
        else if (code < 2048) bytes += 2;
        else if (code >= 55296 && code <= 56319 && i + 1 < text.length
                && text.charCodeAt(i + 1) >= 56320 && text.charCodeAt(i + 1) <= 57343) {
            bytes += 4;
            i += 1;
        } else bytes += 3;
    }
    return bytes;
}

function nativeString(value, label, allowEmpty) {
    if (typeof value !== "string") return nativeError(label + " must be a string");
    if (!allowEmpty && !value) return nativeError(label + " must not be empty");
    if (nativeBytes(value) > NATIVE_MAX_FIELD_BYTES) return nativeError(label + " is too large");
    return nativeOk(value);
}

function nativeStringArray(value, label) {
    if (value === undefined) return nativeOk([]);
    if (!Array.isArray(value) || value.length > 128) return nativeError(label + " must be a bounded array");
    var copy = [];
    for (var i = 0; i < value.length; i++) {
        var checked = nativeString(value[i], label + "[" + i + "]", true);
        if (!checked.ok) return checked;
        copy.push(value[i]);
    }
    return nativeOk(copy);
}

function parseCatalog(raw) {
    var parsed;
    try { parsed = JSON.parse(String(raw || "")); }
    catch (error) { return nativeError("Invalid command catalog JSON: " + error); }
    if (!parsed || parsed.ok !== true || !Array.isArray(parsed.commands))
        return nativeError("Command catalog requires {ok:true,commands:[]}");
    if (parsed.commands.length > NATIVE_MAX_COMMANDS) return nativeError("Command catalog is too large");
    var commands = [];
    for (var i = 0; i < parsed.commands.length; i++) {
        var input = parsed.commands[i];
        if (!input || typeof input !== "object") return nativeError("Command " + i + " must be an object");
        var route = nativeString(input.route, "route", false);
        var binary = nativeString(input.binary, "binary", false);
        var group = nativeString(input.group || "", "group", true);
        var name = nativeString(input.name || "", "name", true);
        var summary = nativeString(input.summary || "", "summary", true);
        var args = nativeString(input.args || "", "args", true);
        var examples = nativeStringArray(input.examples, "examples");
        var aliases = nativeStringArray(input.aliases, "aliases");
        if (!route.ok || !binary.ok || !group.ok || !name.ok || !summary.ok || !args.ok
                || !examples.ok || !aliases.ok)
            return nativeError("Command " + i + " failed schema validation");
        if (route.value.indexOf("omarchy") !== 0) return nativeError("Command " + i + " has a foreign route");
        commands.push({
            route: route.value,
            binary: binary.value,
            group: group.value,
            name: name.value,
            summary: summary.value,
            args: args.value,
            examples: examples.value,
            aliases: aliases.value,
            requires_sudo: input.requires_sudo === true,
            hidden: input.hidden === true
        });
    }
    return nativeOk(commands);
}

function hasRequiredArgs(args) {
    var text = String(args || "");
    var depth = 0;
    for (var i = 0; i < text.length; i++) {
        var character = text.charAt(i);
        if (character === "[") depth += 1;
        else if (character === "]" && depth > 0) depth -= 1;
        else if (character === "<" && depth === 0) return true;
    }
    return false;
}

function parseWords(text) {
    var source = String(text || "");
    var words = [];
    var word = "";
    var quote = "";
    var escaped = false;
    var started = false;
    for (var i = 0; i < source.length; i++) {
        var character = source.charAt(i);
        if (escaped) {
            word += character;
            escaped = false;
            started = true;
        } else if (character === "\\" && quote !== "'") {
            escaped = true;
            started = true;
        } else if (quote) {
            if (character === quote) quote = "";
            else word += character;
            started = true;
        } else if (character === "'" || character === '"') {
            quote = character;
            started = true;
        } else if (/\s/.test(character)) {
            if (started) {
                words.push(word);
                word = "";
                started = false;
            }
        } else {
            word += character;
            started = true;
        }
    }
    if (escaped) return nativeError("Trailing escape");
    if (quote) return nativeError("Unterminated quote");
    if (started) words.push(word);
    return nativeOk(words);
}

function routeArgv(route) {
    var parsed = parseWords(route);
    if (!parsed.ok || parsed.value.length === 0 || parsed.value[0] !== "omarchy") return [];
    return parsed.value;
}

function classify(command) {
    command = command || {};
    var route = String(command.route || "").toLowerCase();
    var group = String(command.group || "").toLowerCase();
    var args = String(command.args || "").toLowerCase();
    var mutatingGroup = /^(refresh|update|install|remove|setup|upgrade|finalize|channel|default|pkg|webapp|tui|drive|branding|font)$/.test(group);
    var destructive = mutatingGroup
        || /(^| )(shutdown|reboot|logout|remove|drop|clear|reset|refresh|reinstall|uninstall|forget)( |$)/.test(route)
        || /window close all|channel set|upgrade to/.test(route)
        || route === "omarchy theme set" || route === "omarchy display text size";
    var systemPower = /omarchy system (shutdown|reboot|logout)/.test(route);
    var graphical = /^omarchy (capture |menu )/.test(route)
        || /omarchy theme (switcher|bg-switcher)/.test(route);
    var interactive = graphical || /interactive|-i\b/.test(args)
        || /^(setup|install|remove|update|upgrade|dev|finalize)$/.test(group)
        || / (switcher|select|picker)$/.test(route);
    var remote = /tailscale send|webapp|ssh|share /.test(route);
    var privileged = command.requires_sudo === true;
    var risk = destructive ? "destructive" : (privileged ? "privileged" : (remote ? "remote" : "safe"));
    return {
        risk: risk,
        lifecycle: graphical || systemPower ? "close"
          : (privileged || interactive || destructive ? "terminal" : "keepOpen"),
        confirm: destructive || remote,
        interactive: interactive,
        privileged: privileged,
        destructive: destructive,
        remote: remote
    };
}

function classifyResolved(command, argv) {
    var policy = classify(command);
    if (!Array.isArray(argv)) return policy;
    var resolved = argv.map(function(value) { return String(value).toLowerCase(); }).join(" ");
    var destructiveArgument = /(^| )(restore|remove|delete|destroy|erase|drop|clear|reset|reinstall|uninstall|forget|prune|format)( |$)/.test(resolved);
    if (!destructiveArgument) return policy;
    return {
        risk: "destructive",
        lifecycle: policy.lifecycle === "close" ? "close" : "terminal",
        confirm: true,
        interactive: policy.interactive,
        privileged: policy.privileged,
        destructive: true,
        remote: policy.remote
    };
}

function nativeHaystack(command) {
    return [command.route, command.summary, command.name, command.args]
        .concat(command.aliases || []).concat(command.examples || []).join(" ");
}

function reservedCommand(command) {
    var route = String(command && command.route || "").replace(/^\s+|\s+$/g, "");
    return /^omarchy agent(?:\s|$)/.test(route);
}

function search(commands, query, scoreFn, limit) {
    if (!Array.isArray(commands)) return [];
    var q = String(query || "").replace(/^\s+|\s+$/g, "");
    if (q.length < 2) return [];
    var maximum = Math.max(1, Math.min(50, Number(limit) || 8));
    var rows = [];
    for (var i = 0; i < commands.length; i++) {
        var command = commands[i];
        if (!command || command.hidden || reservedCommand(command)) continue;
        var haystack = nativeHaystack(command);
        var score;
        if (typeof scoreFn === "function") score = scoreFn(q, haystack);
        else {
            var index = haystack.toLowerCase().indexOf(q.toLowerCase());
            score = index < 0 ? null : index;
        }
        if (score === null || !isFinite(Number(score))) continue;
        var copy = {};
        for (var key in command) {
            if (Object.prototype.hasOwnProperty.call(command, key)) copy[key] = command[key];
        }
        copy.matchScore = Number(score);
        copy.policy = classify(command);
        rows.push(copy);
    }
    rows.sort(function(a, b) {
        if (a.matchScore !== b.matchScore) return a.matchScore - b.matchScore;
        return a.route < b.route ? -1 : (a.route > b.route ? 1 : 0);
    });
    return rows.slice(0, maximum);
}

function nativeStateDetail(context, key) {
    var states = context && context.states;
    return states && states[key] ? "Current: " + states[key] : "";
}

function nativeIntent(id, title, subtitle, argv, score, risk, lifecycle, confirm) {
    return {
        id: id,
        title: title,
        subtitle: subtitle || "",
        argv: argv,
        matchScore: score,
        risk: risk || "safe",
        lifecycle: lifecycle || "close",
        confirm: confirm === true,
        arguments: [],
        provenance: "Omarchy native adapter"
    };
}

function agentIntent(prompt, defaultAgent) {
    var value = String(prompt || "").replace(/^\s+|\s+$/g, "");
    if (nativeBytes(value) > 4096) return null;
    var agent = String(defaultAgent || "");
    var configured = /^[a-z0-9][a-z0-9._-]{0,63}$/.test(agent) && agent !== "unset";
    if (!configured) {
        var setup = nativeIntent("native:agent:setup", "Choose a default coding agent",
            "Required before an LLM prompt can run", ["omarchy", "agent", "--pick"],
            -120, "safe", "close", false);
        setup.actionId = "native.agent-setup";
        setup.actionTitle = "Choose agent";
        setup.learnable = false;
        setup.confirmDetail = "Open Omarchy’s installed default-agent picker.";
        setup.route = "omarchy agent --pick";
        setup.provenance = "Omarchy default-agent launcher";
        return setup;
    }
    var labels = {
        pi: "Pi", omp: "Oh My Pi", opencode: "OpenCode", claude: "Claude Code",
        codex: "Codex", grok: "Grok", gemini: "Gemini", copilot: "GitHub Copilot",
        crush: "Crush"
    };
    var title = value ? "Ask " + (labels[agent] || agent) : "Open " + (labels[agent] || agent);
    var preview = value.replace(/\s+/g, " ");
    if (preview.length > 160) preview = preview.slice(0, 157) + "...";
    var argv = value ? ["omarchy", "agent", "prompt", value] : ["omarchy", "agent"];
    var result = nativeIntent("native:agent:prompt", title,
        preview || "Open the configured Omarchy coding agent", argv,
        -120, "remote", "close", true);
    result.actionId = "native.agent-prompt";
    result.actionTitle = value ? "Send prompt" : "Open agent";
    result.learnable = false;
    result.confirmDetail = "Agent runs unattended · filesystem and network access · Prompt: " + (preview || "(interactive session)");
    result.route = value ? "omarchy agent prompt" : "omarchy agent";
    result.provenance = "Omarchy default-agent launcher";
    return result;
}

function intentRows(query, context) {
    var q = String(query || "").replace(/^\s+|\s+$/g, "");
    var lower = q.toLowerCase();
    var rows = [];
    var match;

    match = q.match(/^(?:remind|reminder)(?:\s+me)?(?:\s+in)?\s+([1-9][0-9]*)(?:\s*(?:minutes?|mins?|m))?(?:\s+(.+))?$/i);
    if (match) {
        var message = match[2] || "";
        var reminderArgv = ["omarchy", "reminder", match[1]];
        if (message) reminderArgv.push(message);
        rows.push(nativeIntent("native:reminder:create", message ? "Remind in " + match[1] + " minutes: " + message : "Remind in " + match[1] + " minutes",
            "Desktop notification reminder", reminderArgv, -100, "safe", "close", false));
    }
    if (/^(show |list )?reminders?$/.test(lower)) {
        var reminderList = nativeIntent("native:reminder:list", "Show reminders", "Structured active reminder list",
            ["omarchy", "reminder", "show", "--json"], -100, "safe", "keepOpen", false);
        reminderList.outputFormat = "reminders";
        rows.push(reminderList);
    }

    match = q.match(/^theme\s+(.+)$/i);
    if (match && context && Array.isArray(context.themes)) {
        var themeQuery = match[1];
        var scoredThemes = [];
        for (var t = 0; t < context.themes.length; t++) {
            var theme = String(context.themes[t]);
            var themeScore = context.scoreFn ? context.scoreFn(themeQuery, theme)
                : theme.toLowerCase().indexOf(themeQuery.toLowerCase());
            if (themeScore !== null && Number(themeScore) >= 0)
                scoredThemes.push({ theme: theme, score: Number(themeScore) });
        }
        scoredThemes.sort(function(a, b) { return a.score - b.score || a.theme.localeCompare(b.theme); });
        for (t = 0; t < Math.min(8, scoredThemes.length); t++)
            rows.push(nativeIntent("native:theme:" + t, "Apply theme " + scoredThemes[t].theme, "Reconfigures the desktop",
                ["omarchy", "theme", "set", scoredThemes[t].theme], -90 + scoredThemes[t].score, "destructive", "close", true));
    }

    match = lower.match(/^(?:screenshot|capture)(?:\s+(smart|region|windows|fullscreen))?(?:\s+(edit|slurp|copy|save))?$/);
    if (match) {
        var useOmasnap = context && context.states && context.states.omasnap === "available";
        var screenshotHelper = context ? String(context.screenshotHelper || "") : "";
        var screenshotBase = screenshotHelper ? [screenshotHelper]
            : (useOmasnap ? ["omasnap"] : ["omarchy", "capture", "screenshot"]);
        if (!match[1] && !match[2]) {
            var captureIntent = nativeIntent("native:capture:screenshot", "Take screenshot",
                "Choose mode and destination · " + (useOmasnap ? "Omasnap" : "system capture"),
                screenshotBase, -95, "safe", "close", false);
            captureIntent.argumentFields = [
                { id: "mode", type: "enum", title: "Capture mode", required: true,
                  values: ["smart", "region", "windows", "fullscreen"] },
                { id: "destination", type: "enum", title: "Destination", required: true,
                  values: ["edit", "copy", "save"] }
            ];
            captureIntent.argumentOrder = ["mode", "destination"];
            captureIntent.argumentValueMap = (screenshotHelper || useOmasnap)
                ? { destination: { edit: "", copy: "--copy", save: "--save" } }
                : { destination: { edit: "slurp", copy: "copy", save: "save" } };
            rows.push(captureIntent);
        } else {
            var mode = match[1] || "smart";
            var destination = match[2] || "edit";
            var screenshotArgv = screenshotBase.concat([mode]);
            if (screenshotHelper || useOmasnap) {
                if (destination === "copy") screenshotArgv.push("--copy");
                else if (destination === "save") screenshotArgv.push("--save");
            } else {
                screenshotArgv.push(destination === "edit" ? "slurp" : destination);
            }
            rows.push(nativeIntent("native:capture:screenshot", "Screenshot " + mode,
                (useOmasnap ? "Omasnap · " : "System capture · ") + destination,
                screenshotArgv, -95, "safe", "close", false));
        }
    }

    if (lower === "background next") rows.push(nativeIntent(
        "native:background:next", "Next background", "Current Omarchy theme",
        ["omarchy", "theme", "bg", "next"], -95, "safe", "close", false));
    if (lower === "background switcher") rows.push(nativeIntent(
        "native:background:switcher", "Open background switcher", "Graphical picker",
        ["omarchy", "theme", "bg-switcher"], -95, "safe", "close", false));
    if (lower === "background" || lower === "set background") {
        var backgroundIntent = nativeIntent(
            "native:background:set", "Set background image", "Enter an image path",
            ["omarchy", "theme", "bg", "set"], -95, "safe", "close", false);
        backgroundIntent.argumentFields = [
            { id: "path", type: "file", title: "Image path", required: true, values: [] }
        ];
        backgroundIntent.argumentOrder = ["path"];
        rows.push(backgroundIntent);
    }

    if (lower === "stay awake") rows.push(nativeIntent("native:toggle:stay-awake", "Stay awake",
        nativeStateDetail(context, "idle"), ["omarchy", "toggle", "idle", "stay-awake"], -95));
    if (lower === "allow idle") rows.push(nativeIntent("native:toggle:allow-idle", "Allow idle",
        nativeStateDetail(context, "idle"), ["omarchy", "toggle", "idle", "allow-idle"], -95));
    if (/^(night ?light|blue ?light)$/.test(lower)) rows.push(nativeIntent("native:toggle:nightlight", "Toggle nightlight",
        nativeStateDetail(context, "nightlight"), ["omarchy", "toggle", "nightlight"], -95));
    if (/^(dnd|do not disturb|silence notifications)$/.test(lower)) rows.push(nativeIntent("native:toggle:dnd", "Toggle notification silencing",
        nativeStateDetail(context, "dnd"), ["omarchy", "toggle", "notification", "silencing"], -95));

    match = lower.match(/^bluetooth\s+(on|off|toggle)$/);
    if (match) rows.push(nativeIntent("native:bluetooth:" + match[1], "Bluetooth " + match[1],
        nativeStateDetail(context, "bluetooth"), ["omarchy", "bluetooth", "power", match[1]], -95));
    match = lower.match(/^bar\s+(on|off|toggle)$/);
    if (match) rows.push(nativeIntent("native:bar:" + match[1], "Bar " + match[1],
        nativeStateDetail(context, "bar"), ["omarchy", "toggle", "bar", match[1]], -95));

    match = lower.match(/^(?:volume|vol)\s+(raise|lower|mute|mute-toggle|[+-][0-9]+)$/);
    if (match) rows.push(nativeIntent("native:audio:volume", "Volume " + match[1], "Show Omarchy OSD",
        ["omarchy", "audio", "output", "volume", match[1] === "mute" ? "mute-toggle" : match[1]], -95));

    match = lower.match(/^brightness\s+([+-]?[0-9]+%?|off|on)$/);
    if (match) {
        var brightness = match[1];
        if (/^[+-]?[0-9]+$/.test(brightness)) brightness += "%";
        rows.push(nativeIntent("native:brightness:display", "Brightness " + brightness,
            "Focused display" + (nativeStateDetail(context, "brightness") ? " · " + nativeStateDetail(context, "brightness") : ""),
            ["omarchy", "brightness", "display", brightness], -95));
    }

    match = lower.match(/^(?:text|font)\s+size\s+(reset|[0-9]+)$/);
    if (match && (match[1] === "reset" || (Number(match[1]) >= 9 && Number(match[1]) <= 20)))
        rows.push(nativeIntent("native:display:text-size", "Text size " + match[1],
            "Changes shell, GTK, and terminal text"
              + (nativeStateDetail(context, "text-size") ? " · " + nativeStateDetail(context, "text-size") : ""),
            ["omarchy", "display", "text", "size", match[1]], -95, "destructive", "close", true));

    return rows;
}

if (typeof module !== "undefined") module.exports = {
    parseCatalog: parseCatalog,
    hasRequiredArgs: hasRequiredArgs,
    parseWords: parseWords,
    routeArgv: routeArgv,
    classify: classify,
    classifyResolved: classifyResolved,
    reservedCommand: reservedCommand,
    search: search,
    intentRows: intentRows,
    agentIntent: agentIntent,
    bytes: nativeBytes
};

// Provider v2 manifest, trigger, context, and NDJSON result validation.

var PROVIDER_CONTEXT_FIELDS = [
    "focusedWindowClass", "focusedWindowTitle", "workspace", "monitor", "time"
];
var PROVIDER_RESULT_TYPES = ["provider", "file", "web", "command", "project"];
var PROVIDER_RISKS = ["safe", "caution", "destructive", "privileged", "remote"];
var PROVIDER_LIFECYCLES = ["close", "keepOpen", "terminal"];

function providerOk(value) { return { ok: true, value: value }; }
function providerError(message) { return { ok: false, error: String(message || "Provider error").slice(0, 512) }; }
function stableId(value) {
    return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/.test(value);
}
function manifestId(value) {
    return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(value);
}
function boundedString(value, label, maximum, allowEmpty) {
    if (typeof value !== "string" || (!allowEmpty && !value)) return providerError(label + " is invalid");
    if (value.length > maximum || /[\u0000\r\n]/.test(value)) return providerError(label + " is too large or contains controls");
    return providerOk(value);
}
function boundedInteger(value, fallback, minimum, maximum) {
    var number = Number(value);
    if (!isFinite(number)) number = fallback;
    return Math.max(minimum, Math.min(maximum, Math.floor(number)));
}
function arrayContains(array, value) { return Array.isArray(array) && array.indexOf(value) >= 0; }

function validateManifest(input, sourceDir, unrestrictedAllowlist) {
    if (!input || typeof input !== "object" || Array.isArray(input)) return providerError("Manifest must be an object");
    if (input.protocol !== 2) return providerError("Manifest protocol must be 2");
    if (!manifestId(input.id)) return providerError("Manifest id is invalid");
    if (input.enabled !== true) return providerError("Manifest must explicitly set enabled=true");
    if (typeof sourceDir !== "string" || sourceDir.charAt(0) !== "/" || sourceDir.indexOf("\u0000") >= 0)
        return providerError("Manifest source directory is invalid");
    if (typeof input.executable !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(input.executable))
        return providerError("Manifest executable must be a relative basename");
    var policy = input.queryPolicy || "triggered";
    if (policy !== "triggered" && policy !== "unrestricted") return providerError("Manifest queryPolicy is invalid");
    if (policy === "unrestricted" && !arrayContains(unrestrictedAllowlist, input.id))
        return providerError("Unrestricted provider is not explicitly allowlisted");
    var triggers = Array.isArray(input.triggers) ? input.triggers.slice() : [];
    if (policy === "triggered" && (triggers.length === 0 || triggers.length > 16))
        return providerError("Triggered provider requires 1-16 triggers");
    for (var i = 0; i < triggers.length; i++) {
        triggers[i] = String(triggers[i] || "").toLowerCase().replace(/^\s+|\s+$/g, "");
        if (!/^[a-z0-9][a-z0-9 ._-]{0,31}$/.test(triggers[i])) return providerError("Provider trigger is invalid");
    }
    var context = Array.isArray(input.context) ? input.context.slice() : [];
    if (context.length > PROVIDER_CONTEXT_FIELDS.length) return providerError("Provider requests too much context");
    var seenContext = {};
    for (i = 0; i < context.length; i++) {
        if (PROVIDER_CONTEXT_FIELDS.indexOf(context[i]) < 0 || seenContext[context[i]])
            return providerError("Provider context field is invalid or duplicated");
        seenContext[context[i]] = true;
    }
    return providerOk({
        protocol: 2,
        id: input.id,
        title: String(input.title || input.id).slice(0, 256),
        executable: input.executable,
        executablePath: sourceDir.replace(/\/+$/, "") + "/" + input.executable,
        sourceDir: sourceDir.replace(/\/+$/, ""),
        queryPolicy: policy,
        triggers: triggers,
        context: context,
        capabilities: Array.isArray(input.capabilities) ? input.capabilities.slice(0, 16) : [],
        timeoutMs: boundedInteger(input.timeoutMs, 900, 100, 5000),
        killAfterMs: boundedInteger(input.killAfterMs, 200, 50, 1000),
        maxRows: boundedInteger(input.maxRows, 8, 1, 32),
        maxLineBytes: boundedInteger(input.maxLineBytes, 16384, 256, 16384)
    });
}

function triggerMatch(manifest, query) {
    if (!manifest || manifest.queryPolicy === "unrestricted") return true;
    var normalized = String(query || "").toLowerCase().replace(/^\s+|\s+$/g, "");
    for (var i = 0; i < manifest.triggers.length; i++) {
        var trigger = manifest.triggers[i];
        if (normalized === trigger || normalized.indexOf(trigger + " ") === 0
                || normalized.indexOf(trigger + ":") === 0) return true;
    }
    return false;
}

function queryBody(manifest, query) {
    var value = String(query || "").replace(/^\s+|\s+$/g, "");
    if (!manifest || manifest.queryPolicy === "unrestricted") return value;
    var lower = value.toLowerCase();
    for (var i = 0; i < manifest.triggers.length; i++) {
        var trigger = manifest.triggers[i];
        if (lower === trigger) return "";
        if (lower.indexOf(trigger + " ") === 0 || lower.indexOf(trigger + ":") === 0)
            return value.slice(trigger.length + 1).replace(/^\s+/, "");
    }
    return value;
}

function filterContext(manifest, context) {
    var filtered = {};
    context = context || {};
    if (!manifest || !Array.isArray(manifest.context)) return filtered;
    for (var i = 0; i < manifest.context.length; i++) {
        var key = manifest.context[i];
        if (context[key] === undefined) continue;
        var value = String(context[key]);
        filtered[key] = value.slice(0, 512);
    }
    return filtered;
}

function providerBasename(value) {
    var text = String(value || "");
    return text.slice(text.lastIndexOf("/") + 1).toLowerCase();
}

function providerCommandView(argv) {
    var index = 0;
    var terminal = false;
    var privileged = false;
    var program = providerBasename(argv[index]);
    if (program === "xdg-terminal-exec") {
        terminal = true;
        index += 1;
        while (index < argv.length && argv[index] !== "--") index += 1;
        if (argv[index] === "--") index += 1;
        program = providerBasename(argv[index]);
    }
    if (program === "sudo" || program === "doas" || program === "pkexec") {
        privileged = true;
        index += 1;
        while (index < argv.length && String(argv[index]).charAt(0) === "-") {
            if (argv[index] === "--") { index += 1; break; }
            index += 1;
        }
        program = providerBasename(argv[index]);
    }
    return { index: index, program: program, terminal: terminal, privileged: privileged };
}

function corePolicy(argv, declaredRisk, declaredLifecycle, declaredConfirm) {
    var view = providerCommandView(argv);
    var opaque = /^(bash|sh|zsh|fish|dash|env|command|setsid|uwsm-app|python|python3|node|ruby|perl|timeout|nice|nohup|stdbuf|chrt|ionice|busybox|xargs|find|systemd-run|parallel|unshare|nsenter|script|bwrap|firejail|flatpak-spawn)$/.test(view.program);
    if (!view.program || opaque) return providerError("Provider action uses an opaque interpreter or launcher");
    var rest = argv.slice(view.index + 1).map(function(value) { return String(value).toLowerCase(); });
    var destructive = /^(rm|rmdir|unlink|shred|dd|wipefs|poweroff|reboot|shutdown|halt)$/.test(view.program)
        || /^mkfs/.test(view.program)
        || (view.program === "pacman" && rest.some(function(value) {
            return value === "-r" || value.indexOf("-r") === 0 || value === "--remove";
        }));
    if (view.program === "omarchy") {
        var route = rest.join(" ");
        destructive = destructive
            || /(^| )(shutdown|reboot|logout|remove|drop|clear|reset|refresh|reinstall|uninstall|forget)( |$)/.test(route)
            || /^(refresh|update|install|remove|setup|upgrade|channel|default|pkg|webapp|tui|drive|branding|font)( |$)/.test(route);
    }
    var risk = destructive ? "destructive" : (view.privileged ? "privileged" : declaredRisk);
    var lifecycle = view.privileged ? "terminal" : declaredLifecycle;
    return providerOk({
        risk: risk,
        lifecycle: lifecycle,
        confirm: destructive ? true : declaredConfirm === true,
        privileged: view.privileged,
        destructive: destructive,
        terminalWrapped: view.terminal
    });
}

function validateAction(input) {
    if (!input || typeof input !== "object" || !stableId(input.id)) return providerError("Provider action id is invalid");
    var title = boundedString(input.title, "Provider action title", 512, false);
    if (!title.ok) return title;
    if (input.executor !== "argv") return providerError("Provider actions must use argv executor");
    if (!Array.isArray(input.argv) || input.argv.length === 0 || input.argv.length > 64)
        return providerError("Provider action argv is invalid");
    var argv = [];
    for (var i = 0; i < input.argv.length; i++) {
        var argument = boundedString(input.argv[i], "Provider argv", 16384, true);
        if (!argument.ok) return argument;
        argv.push(argument.value);
    }
    var risk = input.risk || "safe";
    var lifecycle = input.lifecycle || "close";
    if (PROVIDER_RISKS.indexOf(risk) < 0 || PROVIDER_LIFECYCLES.indexOf(lifecycle) < 0)
        return providerError("Provider action policy is invalid");
    if (risk === "destructive" && input.confirm !== true)
        return providerError("Destructive provider action requires confirmation");
    var enforced = corePolicy(argv, risk, lifecycle, input.confirm)
    if (!enforced.ok) return enforced
    risk = enforced.value.risk
    lifecycle = enforced.value.lifecycle
    return providerOk({
        id: input.id,
        title: input.title,
        subtitle: String(input.subtitle || "").slice(0, 512),
        executor: "argv",
        argv: argv,
        risk: risk,
        lifecycle: lifecycle,
        confirm: enforced.value.confirm,
        arguments: []
    });
}

function validateResult(providerId, input) {
    if (!manifestId(providerId)) return providerError("Provider provenance id is invalid");
    if (!input || typeof input !== "object" || input.protocol !== 2) return providerError("Provider result protocol must be 2");
    if (!stableId(input.id)) return providerError("Provider result id is invalid");
    var type = input.type || "provider";
    if (PROVIDER_RESULT_TYPES.indexOf(type) < 0) return providerError("Provider result type is invalid");
    var title = boundedString(input.title, "Provider result title", 1024, false);
    if (!title.ok) return title;
    var subtitle = boundedString(String(input.subtitle || ""), "Provider result subtitle", 4096, true);
    if (!subtitle.ok) return subtitle;
    if (!Array.isArray(input.actions) || input.actions.length === 0 || input.actions.length > 16)
        return providerError("Provider result actions are invalid");
    var actions = [];
    var actionIds = {};
    for (var i = 0; i < input.actions.length; i++) {
        var checked = validateAction(input.actions[i]);
        if (!checked.ok) return checked;
        if (actionIds[checked.value.id]) return providerError("Provider action ids must be unique");
        actionIds[checked.value.id] = true;
        actions.push(checked.value);
    }
    var fullId = "provider:" + providerId + ":" + input.id;
    if (!stableId(fullId)) return providerError("Namespaced provider result id is invalid");
    var serializedValue;
    try { serializedValue = JSON.stringify(input.value === undefined ? null : input.value); }
    catch (_valueError) { return providerError("Provider result value is not serializable"); }
    if (serializedValue.length > 65536) return providerError("Provider result value is too large");
    var aliases = [];
    if (input.aliases !== undefined && !Array.isArray(input.aliases))
        return providerError("Provider result aliases must be an array");
    var inputAliases = input.aliases || [];
    if (inputAliases.length > 32) return providerError("Provider result has too many aliases");
    for (var aliasIndex = 0; aliasIndex < inputAliases.length; aliasIndex++) {
        var alias = boundedString(inputAliases[aliasIndex], "Provider alias", 80, false);
        if (!alias.ok) return alias;
        aliases.push(alias.value);
    }
    return providerOk({
        id: fullId,
        type: type,
        source: "providers",
        title: input.title,
        subtitle: input.subtitle || "",
        icon: String(input.icon || "").slice(0, 64),
        appIcon: "",
        value: { providerId: providerId, data: input.value === undefined ? null : input.value },
        matchScore: isFinite(Number(input.matchScore)) ? Number(input.matchScore) : 0,
        aliases: aliases,
        actions: actions,
        provenance: providerId
    });
}

if (typeof module !== "undefined") module.exports = {
    CONTEXT_FIELDS: PROVIDER_CONTEXT_FIELDS,
    validateManifest: validateManifest,
    triggerMatch: triggerMatch,
    queryBody: queryBody,
    filterContext: filterContext,
    validateAction: validateAction,
    corePolicy: corePolicy,
    validateResult: validateResult,
    stableId: stableId
};

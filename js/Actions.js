// Typed Result and Action contracts shared by first-party and provider rows.

var RESULT_TYPES = [
    "app", "window", "file", "calculation", "web", "shell", "command",
    "clipboard", "ssh", "provider", "project", "diagnostic"
];
var EXECUTOR_TYPES = ["argv", "builtin", "next", "workflow", "shell"];
var LIFECYCLES = ["close", "keepOpen", "terminal"];
var RISKS = ["safe", "caution", "destructive", "privileged", "remote"];
var ARGUMENT_TYPES = [
    "enum", "integer", "string", "file", "project", "workspace", "monitor",
    "theme", "device"
];
var MAX_ACTIONS = 32;
var MAX_ARGV = 64;
var MAX_STRING_BYTES = 16384;

function actionResult(ok, value, error) {
    return ok ? { ok: true, value: value } : { ok: false, error: String(error || "Invalid value") };
}

function stableId(value) {
    return typeof value === "string"
        && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/.test(value);
}

function actionHas(list, value) {
    return list.indexOf(value) >= 0;
}

function utf8Bytes(value) {
    var text = String(value);
    var bytes = 0;
    var i;
    for (i = 0; i < text.length; i++) {
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

function boundedString(value, label, allowEmpty) {
    if (typeof value !== "string") return actionResult(false, null, label + " must be a string");
    if (!allowEmpty && value.length === 0) return actionResult(false, null, label + " must not be empty");
    if (utf8Bytes(value) > MAX_STRING_BYTES)
        return actionResult(false, null, label + " exceeds " + MAX_STRING_BYTES + " bytes");
    return actionResult(true, value, "");
}

function validateArgv(argv) {
    if (!Array.isArray(argv) || argv.length === 0)
        return actionResult(false, null, "argv must be a non-empty array");
    if (argv.length > MAX_ARGV)
        return actionResult(false, null, "argv exceeds " + MAX_ARGV + " elements");
    var copy = [];
    var i;
    for (i = 0; i < argv.length; i++) {
        var checked = boundedString(argv[i], "argv[" + i + "]", true);
        if (!checked.ok) return checked;
        copy.push(argv[i]);
    }
    return actionResult(true, copy, "");
}

function validateArguments(argumentsList) {
    if (argumentsList === undefined) return actionResult(true, [], "");
    if (!Array.isArray(argumentsList) || argumentsList.length > 16)
        return actionResult(false, null, "arguments must be an array of at most 16 fields");
    var copy = [];
    var seen = {};
    var i;
    for (i = 0; i < argumentsList.length; i++) {
        var field = argumentsList[i];
        if (!field || typeof field !== "object" || !stableId(field.id))
            return actionResult(false, null, "argument " + i + " has an invalid id");
        if (seen[field.id]) return actionResult(false, null, "duplicate argument id: " + field.id);
        if (!actionHas(ARGUMENT_TYPES, field.type))
            return actionResult(false, null, "argument " + field.id + " has an invalid type");
        seen[field.id] = true;
        copy.push({
            id: field.id,
            type: field.type,
            title: String(field.title || field.id),
            required: field.required !== false,
            values: Array.isArray(field.values) ? field.values.slice(0, 256) : []
        });
    }
    return actionResult(true, copy, "");
}

function validateAction(spec) {
    if (!spec || typeof spec !== "object") return actionResult(false, null, "action must be an object");
    if (!stableId(spec.id)) return actionResult(false, null, "action has an invalid id");
    var title = boundedString(spec.title, "action title", false);
    if (!title.ok) return title;
    if (!actionHas(EXECUTOR_TYPES, spec.executor))
        return actionResult(false, null, "action " + spec.id + " has an invalid executor");
    var lifecycle = spec.lifecycle || "close";
    if (!actionHas(LIFECYCLES, lifecycle))
        return actionResult(false, null, "action " + spec.id + " has an invalid lifecycle");
    if (spec.close !== undefined || spec.keepOpen !== undefined)
        return actionResult(false, null, "use lifecycle instead of close/keepOpen flags");
    var risk = spec.risk || "safe";
    if (!actionHas(RISKS, risk))
        return actionResult(false, null, "action " + spec.id + " has an invalid risk");
    if (risk === "destructive" && spec.confirm !== true)
        return actionResult(false, null, "destructive action " + spec.id + " requires confirm");

    var checkedArgv = actionResult(true, [], "");
    if (spec.executor === "argv") checkedArgv = validateArgv(spec.argv);
    if (!checkedArgv.ok) return checkedArgv;
    if (spec.executor === "builtin" && !stableId(spec.builtin))
        return actionResult(false, null, "builtin action requires a stable builtin id");
    if (spec.executor === "next"
            && (!spec.next || typeof spec.next !== "object" || !stableId(spec.next.type)))
        return actionResult(false, null, "next action requires a stable next.type");
    if (spec.executor === "workflow" && !stableId(spec.workflowId))
        return actionResult(false, null, "workflow action requires a stable workflowId");
    if (spec.executor === "shell") {
        var command = boundedString(spec.command, "shell command", false);
        if (!command.ok) return command;
        if (spec.trusted !== true)
            return actionResult(false, null, "shell action requires explicit trusted=true");
    }

    var checkedArguments = validateArguments(spec.arguments);
    if (!checkedArguments.ok) return checkedArguments;
    return actionResult(true, {
        id: spec.id,
        title: spec.title,
        subtitle: typeof spec.subtitle === "string" ? spec.subtitle : "",
        executor: spec.executor,
        argv: checkedArgv.value,
        builtin: spec.executor === "builtin" ? spec.builtin : "",
        next: spec.executor === "next" ? { type: spec.next.type } : null,
        workflowId: spec.executor === "workflow" ? spec.workflowId : "",
        command: spec.executor === "shell" ? spec.command : "",
        trusted: spec.executor === "shell" ? true : false,
        arguments: checkedArguments.value,
        risk: risk,
        confirm: spec.confirm === true,
        lifecycle: lifecycle
    }, "");
}

function makeAction(spec) {
    return validateAction(spec);
}

function validateResult(spec) {
    if (!spec || typeof spec !== "object") return actionResult(false, null, "result must be an object");
    if (!stableId(spec.id)) return actionResult(false, null, "result has an invalid id");
    if (!actionHas(RESULT_TYPES, spec.type)) return actionResult(false, null, "result has an invalid type");
    if (!stableId(spec.source)) return actionResult(false, null, "result has an invalid source");
    var title = boundedString(spec.title, "result title", false);
    if (!title.ok) return title;
    var subtitle = boundedString(spec.subtitle || "", "result subtitle", true);
    if (!subtitle.ok) return subtitle;
    if (!Array.isArray(spec.actions) || spec.actions.length === 0)
        return actionResult(false, null, "result requires at least one action");
    if (spec.actions.length > MAX_ACTIONS)
        return actionResult(false, null, "result exceeds " + MAX_ACTIONS + " actions");

    var actions = [];
    var actionIds = {};
    var i;
    for (i = 0; i < spec.actions.length; i++) {
        var checked = validateAction(spec.actions[i]);
        if (!checked.ok) return checked;
        if (actionIds[checked.value.id])
            return actionResult(false, null, "duplicate action id: " + checked.value.id);
        actionIds[checked.value.id] = true;
        actions.push(checked.value);
    }
    return actionResult(true, {
        id: spec.id,
        type: spec.type,
        source: spec.source,
        title: spec.title,
        subtitle: spec.subtitle || "",
        icon: typeof spec.icon === "string" ? spec.icon : "",
        appIcon: typeof spec.appIcon === "string" ? spec.appIcon : "",
        value: spec.value === undefined ? null : spec.value,
        matchScore: isFinite(Number(spec.matchScore)) ? Number(spec.matchScore) : 0,
        aliases: Array.isArray(spec.aliases) ? spec.aliases.slice(0, 64) : [],
        actions: actions
    }, "");
}

function makeResult(spec) {
    return validateResult(spec);
}

function primaryAction(result) {
    var checked = validateResult(result);
    return checked.ok ? actionResult(true, checked.value.actions[0], "") : checked;
}

if (typeof module !== "undefined") module.exports = {
    RESULT_TYPES: RESULT_TYPES,
    EXECUTOR_TYPES: EXECUTOR_TYPES,
    LIFECYCLES: LIFECYCLES,
    RISKS: RISKS,
    ARGUMENT_TYPES: ARGUMENT_TYPES,
    MAX_ACTIONS: MAX_ACTIONS,
    MAX_ARGV: MAX_ARGV,
    MAX_STRING_BYTES: MAX_STRING_BYTES,
    stableId: stableId,
    validateArgv: validateArgv,
    validateAction: validateAction,
    validateResult: validateResult,
    makeAction: makeAction,
    makeResult: makeResult,
    primaryAction: primaryAction,
    utf8Bytes: utf8Bytes
};

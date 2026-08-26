// Local aggregate-only metrics. No query, argument, clipboard, path, or output content.

var METRIC_COUNTERS = [
    "opens", "closes", "cancellations", "activations", "successes", "failures",
    "secondaryActions", "selectionMoves", "actionModeEntries"
];
var METRIC_SOURCES = [
    "apps", "windows", "files", "calc", "web", "run", "system", "clipboard",
    "ssh", "native", "projects", "workflows", "providers"
];
var METRIC_TYPES = [
    "app", "window", "file", "calculation", "web", "shell", "command",
    "clipboard", "ssh", "provider", "project", "diagnostic"
];
var LATENCY_KINDS = ["render", "async", "completion"];
var LATENCY_BUCKETS = ["lt50", "50to199", "200to999", "gte1000"];
var MAX_COUNTER = 1000000000;

function emptyMap(keys) {
    var map = {};
    for (var i = 0; i < keys.length; i++) map[keys[i]] = 0;
    return map;
}

function create() {
    return {
        version: 1,
        counters: emptyMap(METRIC_COUNTERS),
        sources: {},
        types: {},
        actions: {},
        latency: {
            render: emptyMap(LATENCY_BUCKETS),
            async: emptyMap(LATENCY_BUCKETS),
            completion: emptyMap(LATENCY_BUCKETS)
        },
        workflows: { runs: 0, successes: 0, failures: 0, cancellations: 0, steps: 0 }
    };
}

function boundedCount(value) {
    var number = Number(value);
    if (!isFinite(number) || number < 0) return 0;
    return Math.min(MAX_COUNTER, Math.floor(number));
}

function copyCounts(input, allowed) {
    var output = {};
    if (!input || typeof input !== "object" || Array.isArray(input)) return output;
    for (var key in input) {
        if (!Object.prototype.hasOwnProperty.call(input, key) || allowed.indexOf(key) < 0) continue;
        output[key] = boundedCount(input[key]);
    }
    return output;
}

var ACTION_PREFIXES = {
    apps: ["app.", "learning."],
    windows: ["window."],
    files: ["file.", "learning."],
    calc: ["calculation."],
    web: ["web."],
    system: ["system.", "learning."],
    clipboard: ["clipboard."],
    ssh: ["ssh.", "learning."],
    native: ["native.", "learning."],
    projects: ["project.", "learning."],
    workflows: ["workflow.", "learning."]
};

function allowedActionId(source, value) {
    if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{1,80}$/.test(value)) return false;
    var prefixes = ACTION_PREFIXES[source] || [];
    for (var i = 0; i < prefixes.length; i++)
        if (value.indexOf(prefixes[i]) === 0) return true;
    return false;
}

function allowedActionKey(key) {
    if (typeof key !== "string") return false;
    var slash = key.indexOf("/");
    return slash > 0 && allowedActionId(key.slice(0, slash), key.slice(slash + 1));
}

function sanitize(value) {
    var state = create();
    if (!value || typeof value !== "object" || value.version !== 1) return state;
    var counters = copyCounts(value.counters, METRIC_COUNTERS);
    for (var counter in counters) state.counters[counter] = counters[counter];
    state.sources = copyCounts(value.sources, METRIC_SOURCES);
    state.types = copyCounts(value.types, METRIC_TYPES);
    if (value.actions && typeof value.actions === "object" && !Array.isArray(value.actions)) {
        for (var action in value.actions) {
            if (Object.prototype.hasOwnProperty.call(value.actions, action) && allowedActionKey(action))
                state.actions[action] = boundedCount(value.actions[action]);
        }
    }
    if (value.latency && typeof value.latency === "object") {
        for (var i = 0; i < LATENCY_KINDS.length; i++) {
            var kind = LATENCY_KINDS[i];
            var buckets = copyCounts(value.latency[kind], LATENCY_BUCKETS);
            for (var bucket in buckets) state.latency[kind][bucket] = buckets[bucket];
        }
    }
    var workflowKeys = ["runs", "successes", "failures", "cancellations", "steps"];
    var workflows = copyCounts(value.workflows, workflowKeys);
    for (var workflow in workflows) state.workflows[workflow] = workflows[workflow];
    return state;
}

function copy(state) { return sanitize(state); }
function incrementValue(value, amount) {
    return Math.min(MAX_COUNTER, boundedCount(value) + Math.max(0, boundedCount(amount === undefined ? 1 : amount)));
}

function increment(state, event, amount) {
    var next = copy(state);
    if (METRIC_COUNTERS.indexOf(event) >= 0)
        next.counters[event] = incrementValue(next.counters[event], amount);
    return next;
}

function recordActivation(state, result, action, secondary) {
    var next = increment(state, "activations", 1);
    if (secondary) next.counters.secondaryActions = incrementValue(next.counters.secondaryActions, 1);
    if (result && METRIC_SOURCES.indexOf(result.source) >= 0)
        next.sources[result.source] = incrementValue(next.sources[result.source], 1);
    if (result && METRIC_TYPES.indexOf(result.type) >= 0)
        next.types[result.type] = incrementValue(next.types[result.type], 1);
    if (result && action && allowedActionId(result.source, action.id)) {
        var actionKey = result.source + "/" + action.id;
        next.actions[actionKey] = incrementValue(next.actions[actionKey], 1);
    }
    return next;
}

function latencyBucket(milliseconds) {
    var value = Number(milliseconds);
    if (!isFinite(value) || value < 0) return "";
    if (value < 50) return "lt50";
    if (value < 200) return "50to199";
    if (value < 1000) return "200to999";
    return "gte1000";
}

function recordLatency(state, kind, milliseconds) {
    var next = copy(state);
    if (LATENCY_KINDS.indexOf(kind) < 0) return next;
    var bucket = latencyBucket(milliseconds);
    if (bucket) next.latency[kind][bucket] = incrementValue(next.latency[kind][bucket], 1);
    return next;
}

function recordWorkflow(state, steps, outcome) {
    var next = copy(state);
    next.workflows.runs = incrementValue(next.workflows.runs, 1);
    next.workflows.steps = incrementValue(next.workflows.steps, steps);
    if (outcome === "success") next.workflows.successes = incrementValue(next.workflows.successes, 1);
    else if (outcome === "failure") next.workflows.failures = incrementValue(next.workflows.failures, 1);
    else if (outcome === "canceled") next.workflows.cancellations = incrementValue(next.workflows.cancellations, 1);
    return next;
}

function summary(state) {
    var safe = copy(state);
    return {
        opens: safe.counters.opens,
        activations: safe.counters.activations,
        secondaryActions: safe.counters.secondaryActions,
        successes: safe.counters.successes,
        failures: safe.counters.failures,
        workflows: safe.workflows.runs
    };
}

if (typeof module !== "undefined") module.exports = {
    COUNTERS: METRIC_COUNTERS,
    SOURCES: METRIC_SOURCES,
    TYPES: METRIC_TYPES,
    create: create,
    sanitize: sanitize,
    increment: increment,
    recordActivation: recordActivation,
    recordLatency: recordLatency,
    recordWorkflow: recordWorkflow,
    latencyBucket: latencyBucket,
    allowedActionId: allowedActionId,
    allowedActionKey: allowedActionKey,
    summary: summary
};

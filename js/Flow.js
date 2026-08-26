// Immutable bounded navigation and execution state for Omnibox.

var FLOW_MODES = ["Search", "Actions", "Arguments", "Confirm", "Running", "Result"];
var FLOW_MAX_DEPTH = 4;

function flowOk(value) { return { ok: true, value: value }; }
function flowError(message) { return { ok: false, error: String(message || "Invalid flow transition") }; }

function flowCopyData(data) {
    if (!data || typeof data !== "object") return data;
    if (Array.isArray(data)) return data.slice();
    var copy = {};
    for (var key in data) {
        if (Object.prototype.hasOwnProperty.call(data, key)) copy[key] = data[key];
    }
    return copy;
}

function flowFrame(mode, title, data) {
    return {
        mode: mode,
        title: String(title || mode),
        query: "",
        selectedId: "",
        data: flowCopyData(data || {})
    };
}

function flowCopy(state) {
    var frames = [];
    var i;
    for (i = 0; i < state.frames.length; i++) {
        frames.push({
            mode: state.frames[i].mode,
            title: state.frames[i].title,
            query: state.frames[i].query,
            selectedId: state.frames[i].selectedId,
            data: flowCopyData(state.frames[i].data)
        });
    }
    return {
        frames: frames,
        runSerial: state.runSerial,
        activeToken: state.activeToken,
        closed: state.closed === true
    };
}

function flowValidState(state) {
    return state && Array.isArray(state.frames) && state.frames.length > 0
        && state.frames.length <= FLOW_MAX_DEPTH;
}

function create(data) {
    return flowOk({
        frames: [flowFrame("Search", "Search", data || {})],
        runSerial: 0,
        activeToken: "",
        closed: false
    });
}

function current(state) {
    if (!flowValidState(state)) return flowError("Invalid flow state");
    return flowOk(state.frames[state.frames.length - 1]);
}

function flowAllowed(from, to) {
    if (from === "Search") return ["Actions", "Arguments", "Confirm"].indexOf(to) >= 0;
    if (from === "Actions") return ["Arguments", "Confirm"].indexOf(to) >= 0;
    if (from === "Arguments") return ["Arguments", "Confirm"].indexOf(to) >= 0;
    return false;
}

function push(state, mode, title, data) {
    if (!flowValidState(state)) return flowError("Invalid flow state");
    if (FLOW_MODES.indexOf(mode) < 0 || mode === "Running" || mode === "Result")
        return flowError("Invalid interactive mode: " + mode);
    if (state.frames.length >= FLOW_MAX_DEPTH) return flowError("Flow depth exceeds " + FLOW_MAX_DEPTH);
    var from = state.frames[state.frames.length - 1].mode;
    if (!flowAllowed(from, mode)) return flowError("Illegal transition from " + from + " to " + mode);
    var next = flowCopy(state);
    next.closed = false;
    next.frames.push(flowFrame(mode, title, data));
    return flowOk(next);
}

function pop(state) {
    if (!flowValidState(state)) return flowError("Invalid flow state");
    var next = flowCopy(state);
    if (next.frames.length === 1) {
        next.closed = true;
        return flowOk(next);
    }
    if (next.frames[next.frames.length - 1].mode === "Running")
        return flowError("Cancel a running action before navigating back");
    next.frames.pop();
    next.activeToken = "";
    return flowOk(next);
}

function flowUpdateCurrent(state, property, value) {
    if (!flowValidState(state)) return flowError("Invalid flow state");
    if (state.frames[state.frames.length - 1].mode === "Running")
        return flowError("Cannot edit a running action");
    var next = flowCopy(state);
    next.frames[next.frames.length - 1][property] = String(value || "");
    return flowOk(next);
}

function setQuery(state, query) { return flowUpdateCurrent(state, "query", query); }
function setSelection(state, selectedId) { return flowUpdateCurrent(state, "selectedId", selectedId); }

function begin(state, title, data) {
    if (!flowValidState(state)) return flowError("Invalid flow state");
    var mode = state.frames[state.frames.length - 1].mode;
    if (["Search", "Actions", "Arguments", "Confirm"].indexOf(mode) < 0)
        return flowError("Cannot begin from " + mode);
    var next = flowCopy(state);
    next.runSerial += 1;
    next.activeToken = String(next.runSerial);
    var runningFrame = flowFrame("Running", title || "Running", data);
    if (next.frames.length >= FLOW_MAX_DEPTH) next.frames[next.frames.length - 1] = runningFrame;
    else next.frames.push(runningFrame);
    next.frames[next.frames.length - 1].data.token = next.activeToken;
    return flowOk({ state: next, token: next.activeToken });
}

function flowFinish(state, token, ok, message, data) {
    if (!flowValidState(state)) return flowError("Invalid flow state");
    if (state.frames[state.frames.length - 1].mode !== "Running")
        return flowError("No action is running");
    if (!token || String(token) !== String(state.activeToken)) return flowError("Stale run token");
    var next = flowCopy(state);
    var running = next.frames.pop();
    next.frames.push(flowFrame("Result", ok ? "Success" : "Error", {
        ok: ok,
        message: String(message || ""),
        result: flowCopyData(data || {}),
        actionTitle: running.title,
        token: String(token),
        canceled: false
    }));
    next.activeToken = "";
    return flowOk(next);
}

function succeed(state, token, message, data) {
    return flowFinish(state, token, true, message, data);
}

function fail(state, token, message, data) {
    return flowFinish(state, token, false, message, data);
}

function cancel(state, token) {
    if (!flowValidState(state)) return flowError("Invalid flow state");
    if (state.frames[state.frames.length - 1].mode !== "Running") return pop(state);
    if (!token || String(token) !== String(state.activeToken)) return flowError("Stale run token");
    var next = flowCopy(state);
    var running = next.frames.pop();
    next.frames.push(flowFrame("Result", "Canceled", {
        ok: false,
        message: "Canceled",
        result: {},
        actionTitle: running.title,
        token: String(token),
        canceled: true
    }));
    next.activeToken = "";
    return flowOk(next);
}

function reset(data) {
    return create(data);
}

if (typeof module !== "undefined") module.exports = {
    MODES: FLOW_MODES,
    MAX_DEPTH: FLOW_MAX_DEPTH,
    create: create,
    current: current,
    push: push,
    pop: pop,
    setQuery: setQuery,
    setSelection: setSelection,
    begin: begin,
    succeed: succeed,
    fail: fail,
    cancel: cancel,
    reset: reset
};

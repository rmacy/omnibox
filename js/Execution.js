// Pure execution policy helpers. Process lifecycle remains in QML.

function executionCopyArgv(argv) {
    return Array.isArray(argv) ? argv.slice() : [];
}

function argvFor(action) {
    action = action || {};
    var argv = executionCopyArgv(action.argv);
    if (action.risk === "privileged" && argv.length > 0 && argv[0] !== "xdg-terminal-exec")
        return ["xdg-terminal-exec", "--"].concat(argv);
    if (action.lifecycle === "terminal" && argv.length > 0 && argv[0] !== "xdg-terminal-exec")
        return ["xdg-terminal-exec", "--"].concat(argv);
    return argv;
}

function requiresConfirmation(action) {
    return !!action && (action.confirm === true || action.risk === "destructive");
}

function boundedAppend(current, chunk, maximum) {
    var limit = Number(maximum);
    if (!isFinite(limit) || limit < 0) limit = 0;
    var existing = String(current || "");
    if (existing.length >= limit) return existing.slice(0, limit);
    return (existing + String(chunk || "")).slice(0, limit);
}

function redactedPlan(action) {
    action = action || {};
    if (action.executor === "shell") return ["trusted shell action"];
    var argv = argvFor(action);
    var redacted = [];
    for (var i = 0; i < argv.length; i++) {
        var value = String(argv[i]);
        redacted.push(value.length > 160 ? value.slice(0, 157) + "..." : value);
    }
    return redacted;
}

if (typeof module !== "undefined") module.exports = {
    argvFor: argvFor,
    requiresConfirmation: requiresConfirmation,
    boundedAppend: boundedAppend,
    redactedPlan: redactedPlan
};

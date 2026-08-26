// Deterministic query parsing for Omnibox search modes and safe aliases.

function queryStableId(value) {
    return typeof value === "string"
        && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/.test(value);
}

function queryNormalize(value) {
    return String(value === undefined || value === null ? "" : value)
        .replace(/^\s+|\s+$/g, "")
        .toLowerCase();
}

function queryAlias(aliases, normalized) {
    if (!aliases || typeof aliases !== "object" || !normalized) return null;
    var key;
    for (key in aliases) {
        if (!Object.prototype.hasOwnProperty.call(aliases, key)) continue;
        if (queryNormalize(key) !== normalized) continue;
        var value = aliases[key];
        if (typeof value === "string") {
            return queryStableId(value) ? { resultId: value, actionId: "" } : null;
        }
        if (!value || typeof value !== "object") return null;
        var resultId = String(value.resultId || "");
        var actionId = String(value.actionId || "");
        if (!queryStableId(resultId)) return null;
        if (actionId && !queryStableId(actionId)) return null;
        return { resultId: resultId, actionId: actionId };
    }
    return null;
}

function parse(raw, aliases) {
    var source = String(raw === undefined || raw === null ? "" : raw);
    var text = source.replace(/^\s+|\s+$/g, "");
    var mode = "Search";
    var body = text;
    var forced = false;

    if (text.charAt(0) === ">") {
        mode = "Shell";
        body = text.slice(1).replace(/^\s+/, "");
        forced = true;
    } else if (text.charAt(0) === "=") {
        mode = "Calculator";
        body = text.slice(1).replace(/^\s+/, "");
        forced = true;
    }

    var alias = mode === "Search" ? queryAlias(aliases, queryNormalize(text)) : null;
    return {
        raw: source,
        text: text,
        body: body,
        mode: mode,
        forced: forced,
        aliasResultId: alias ? alias.resultId : "",
        aliasActionId: alias ? alias.actionId : ""
    };
}

if (typeof module !== "undefined") module.exports = {
    parse: parse,
    normalize: queryNormalize,
    stableId: queryStableId
};

// Cross-source ranking. Lower scores rank first.

function rankingFinite(value, fallback) {
    var number = Number(value);
    return isFinite(number) ? number : fallback;
}

function rankingClamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value));
}

function rankingNormalize(value) {
    return String(value === undefined || value === null ? "" : value)
        .replace(/^\s+|\s+$/g, "")
        .toLowerCase();
}

function rankingAliases(candidate) {
    if (!candidate) return [];
    if (Array.isArray(candidate.aliases)) return candidate.aliases;
    if (typeof candidate.aliases === "string") return candidate.aliases.split(/\s+/);
    return [];
}

function rankingWordBoundary(query, text) {
    if (!query || !text) return false;
    if (text.indexOf(query) === 0) return true;
    var index = text.indexOf(query);
    while (index >= 0) {
        if (index === 0 || /[\s._:/-]/.test(text.charAt(index - 1))) return true;
        index = text.indexOf(query, index + 1);
    }
    return false;
}

function rankingPinned(pins, candidate) {
    if (!pins || !candidate) return false;
    if (Array.isArray(pins)) return pins.indexOf(candidate.id) >= 0;
    return !!pins[candidate.id];
}

function rankingUsage(usage, candidate) {
    if (!usage || !candidate || !usage[candidate.id]) return {};
    return usage[candidate.id];
}

function rankingNegative(value) {
    var bounded = Number(value);
    return bounded === 0 ? 0 : -bounded;
}

function explain(query, candidate, signals) {
    candidate = candidate || {};
    signals = signals || {};
    var normalizedQuery = rankingNormalize(query);
    var title = rankingNormalize(candidate.title || candidate.label || "");
    var aliases = rankingAliases(candidate);
    var exactAlias = false;
    var prefixAlias = false;
    var i;
    for (i = 0; i < aliases.length; i++) {
        var alias = rankingNormalize(aliases[i]);
        if (alias === normalizedQuery && normalizedQuery) exactAlias = true;
        if (alias.indexOf(normalizedQuery) === 0 && normalizedQuery) prefixAlias = true;
    }

    var usageEntry = rankingUsage(signals.usage, candidate);
    var count = Math.max(0, rankingFinite(usageEntry.count, 0));
    var lastUsed = Math.max(0, rankingFinite(usageEntry.lastUsed, 0));
    var now = Math.max(0, rankingFinite(signals.now, Date.now()));
    var ageDays = lastUsed > 0 && now >= lastUsed ? (now - lastUsed) / 86400000 : 9999;
    var recency = lastUsed > 0 ? rankingNegative(rankingClamp(12 - ageDays, 0, 12)) : 0;
    var priors = signals.sourcePriors || {};

    var parts = {
        match: rankingFinite(candidate.matchScore !== undefined ? candidate.matchScore : candidate.score, 1000),
        exact: normalizedQuery && title === normalizedQuery ? -80 : 0,
        alias: exactAlias ? -90 : (prefixAlias ? -38 : 0),
        prefix: normalizedQuery && title.indexOf(normalizedQuery) === 0 ? -35 : 0,
        word: normalizedQuery && rankingWordBoundary(normalizedQuery, title) ? -15 : 0,
        intent: signals.intentSource && candidate.source === signals.intentSource ? -25 : 0,
        pin: rankingPinned(signals.pins, candidate) ? -100 : 0,
        frequency: rankingNegative(rankingClamp(4 * Math.log(count + 1) / Math.LN2, 0, 18)),
        recency: recency,
        prior: rankingClamp(rankingFinite(priors[candidate.source], 0), -5, 5)
    };
    var total = 0;
    for (var key in parts) {
        if (Object.prototype.hasOwnProperty.call(parts, key)) total += parts[key];
    }
    parts.total = rankingFinite(total, 1000);
    return parts;
}

function rankingCopy(candidate) {
    var copy = {};
    for (var key in candidate) {
        if (Object.prototype.hasOwnProperty.call(candidate, key)) copy[key] = candidate[key];
    }
    return copy;
}

function rank(query, candidates, signals) {
    if (!Array.isArray(candidates)) return [];
    var ranked = [];
    var i;
    for (i = 0; i < candidates.length; i++) {
        if (!candidates[i] || typeof candidates[i] !== "object") continue;
        var copy = rankingCopy(candidates[i]);
        copy.scoreParts = explain(query, candidates[i], signals);
        copy.score = copy.scoreParts.total;
        copy.__rankingIndex = i;
        ranked.push(copy);
    }
    ranked.sort(function(a, b) {
        if (a.score !== b.score) return a.score - b.score;
        var aId = String(a.id || a.rowKey || "");
        var bId = String(b.id || b.rowKey || "");
        if (aId !== bId) return aId < bId ? -1 : 1;
        return a.__rankingIndex - b.__rankingIndex;
    });
    for (i = 0; i < ranked.length; i++) delete ranked[i].__rankingIndex;
    return ranked;
}

if (typeof module !== "undefined") module.exports = {
    explain: explain,
    rank: rank,
    normalize: rankingNormalize
};

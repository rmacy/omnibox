// Ordered source registry. Source failures stay local to that source.

function registryStableId(value) {
    return typeof value === "string"
        && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/.test(value);
}

function registryError(message) {
    return { ok: false, error: String(message || "Registry error").slice(0, 512) };
}

function registryCopyDefinition(definition) {
    return {
        id: definition.id,
        label: String(definition.label || definition.id),
        order: isFinite(Number(definition.order)) ? Number(definition.order) : 0,
        collect: definition.collect,
        available: definition.available === undefined ? true : definition.available
    };
}

function build(definitions) {
    if (!Array.isArray(definitions)) return registryError("Definitions must be an array");
    var ordered = [];
    var byId = {};
    var i;
    for (i = 0; i < definitions.length; i++) {
        var definition = definitions[i];
        if (!definition || typeof definition !== "object")
            return registryError("Definition " + i + " must be an object");
        if (!registryStableId(definition.id))
            return registryError("Definition " + i + " has an invalid id");
        if (Object.prototype.hasOwnProperty.call(byId, definition.id))
            return registryError("Duplicate source id: " + definition.id);
        if (typeof definition.collect !== "function")
            return registryError("Source " + definition.id + " requires collect()");
        if (definition.available !== undefined
                && typeof definition.available !== "boolean"
                && typeof definition.available !== "function")
            return registryError("Source " + definition.id + " has invalid availability");
        var copy = registryCopyDefinition(definition);
        ordered.push(copy);
        byId[copy.id] = copy;
    }
    ordered.sort(function(a, b) {
        if (a.order !== b.order) return a.order - b.order;
        return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
    });
    return { ok: true, value: { ordered: ordered, byId: byId } };
}

function registryAvailable(definition, context) {
    if (typeof definition.available === "function")
        return definition.available(context) !== false;
    return definition.available !== false;
}

function collect(registry, parsed, context) {
    if (!registry || !Array.isArray(registry.ordered))
        return registryError("Invalid registry");
    var results = [];
    var diagnostics = [];
    var i;
    for (i = 0; i < registry.ordered.length; i++) {
        var definition = registry.ordered[i];
        var available = false;
        try {
            available = registryAvailable(definition, context);
        } catch (availabilityError) {
            diagnostics.push({
                source: definition.id,
                error: String(availabilityError).slice(0, 512)
            });
            continue;
        }
        if (!available) continue;
        try {
            var rows = definition.collect(parsed, context);
            if (!Array.isArray(rows)) {
                diagnostics.push({ source: definition.id, error: "collect() did not return an array" });
                continue;
            }
            var j;
            for (j = 0; j < rows.length; j++) {
                if (!rows[j] || typeof rows[j] !== "object") continue;
                var row = {};
                var key;
                for (key in rows[j]) {
                    if (Object.prototype.hasOwnProperty.call(rows[j], key)) row[key] = rows[j][key];
                }
                if (!row.source) row.source = definition.id;
                results.push(row);
            }
        } catch (collectError) {
            diagnostics.push({
                source: definition.id,
                error: String(collectError).slice(0, 512)
            });
        }
    }
    return { ok: true, value: { results: results, diagnostics: diagnostics } };
}

if (typeof module !== "undefined") module.exports = {
    build: build,
    collect: collect,
    stableId: registryStableId
};

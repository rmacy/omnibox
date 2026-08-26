// Deterministic project identities, registered workflow plans, and runtime state.

var WORKFLOW_ACTIONS = [
    "project.open-or-focus-editor",
    "project.open-or-focus-terminal",
    "project.open-git-remote"
];
var WORKFLOW_PARAMETER_TYPES = ["project", "file", "enum", "integer", "string"];
var WORKFLOW_MAX_STEPS = 32;

function workflowOk(value) { return { ok: true, value: value }; }
function workflowError(message) { return { ok: false, error: String(message || "Workflow error").slice(0, 512) }; }
function stableId(value) {
    return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/.test(value);
}

function stableHash(value) {
    var text = String(value || "");
    var hash = 5381;
    for (var i = 0; i < text.length; i++) hash = ((hash << 5) + hash) ^ text.charCodeAt(i);
    return (hash >>> 0).toString(16) + "-" + text.length;
}

function validPath(path) {
    return typeof path === "string" && path.charAt(0) === "/" && path.indexOf("\u0000") < 0
        && !/(^|\/)\.\.(\/|$)/.test(path) && path.length <= 4096;
}

function projectId(path) {
    return validPath(path) ? "project:" + stableHash(path.replace(/\/+$/, "")) : "";
}

function sessionName(project) {
    var name = String(project && project.name || "project").toLowerCase()
        .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 20) || "project";
    var path = String(project && project.path || "");
    return ("omnibox-" + name + "-" + stableHash(path).split("-")[0]).slice(0, 48);
}

function normalizeRemote(remote) {
    var value = String(remote || "").replace(/^\s+|\s+$/g, "");
    if (!value || value.indexOf("\u0000") >= 0) return "";
    var scp = value.match(/^git@([A-Za-z0-9.-]+):([A-Za-z0-9._/-]+?)(?:\.git)?$/);
    if (scp) return "https://" + scp[1] + "/" + scp[2].replace(/\.git$/, "");
    var ssh = value.match(/^ssh:\/\/git@([A-Za-z0-9.-]+)\/([A-Za-z0-9._/-]+?)(?:\.git)?$/);
    if (ssh) return "https://" + ssh[1] + "/" + ssh[2].replace(/\.git$/, "");
    var https = value.match(/^https:\/\/([^/@:]+\.)*([A-Za-z0-9.-]+)\/([A-Za-z0-9._/-]+?)(?:\.git)?$/);
    if (https && value.indexOf("@") < 0) return value.replace(/\.git$/, "");
    return "";
}

function validateProject(project) {
    if (!project || typeof project !== "object") return workflowError("Project must be an object");
    if (!validPath(project.path)) return workflowError("Project path must be an absolute safe path");
    var path = project.path.replace(/\/+$/, "");
    var id = project.id || projectId(path);
    if (!stableId(id) || id !== projectId(path)) return workflowError("Project id does not match path");
    var name = String(project.name || path.slice(path.lastIndexOf("/") + 1));
    if (!name || name.length > 256 || /[\r\n\t]/.test(name)) return workflowError("Project name is invalid");
    var branch = String(project.branch || "");
    if (branch.length > 256 || /[\r\n\t]/.test(branch)) return workflowError("Project branch is invalid");
    var marker = String(project.marker || ".git");
    if (marker !== ".git") return workflowError("Project marker is invalid");
    var refreshedAt = Number(project.refreshedAt);
    if (!isFinite(refreshedAt) || refreshedAt < 0) refreshedAt = 0;
    var remote = project.remote ? normalizeRemote(project.remote) : "";
    if (project.remote && !remote) return workflowError("Project remote is unsafe");
    return workflowOk({ id: id, name: name, path: path, marker: marker,
        branch: branch, remote: remote, refreshedAt: refreshedAt });
}

function copyArray(value) { return Array.isArray(value) ? value.slice() : []; }

function validateConfig(value) {
    if (!Array.isArray(value) || value.length > 64) return workflowError("Workflows must be an array of at most 64 entries");
    var workflows = [];
    var ids = {};
    for (var i = 0; i < value.length; i++) {
        var input = value[i];
        if (!input || typeof input !== "object" || Array.isArray(input)) return workflowError("Workflow " + i + " must be an object");
        if (input.argv !== undefined || input.command !== undefined || input.shell !== undefined)
            return workflowError("Workflow " + i + " contains executable content");
        if (!stableId(input.id) || ids[input.id]) return workflowError("Workflow " + i + " has an invalid or duplicate id");
        var title = String(input.title || "");
        if (!title || title.length > 256) return workflowError("Workflow " + input.id + " has an invalid title");
        var aliases = copyArray(input.aliases);
        if (aliases.length > 32) return workflowError("Workflow " + input.id + " has too many aliases");
        for (var a = 0; a < aliases.length; a++) {
            if (typeof aliases[a] !== "string" || !aliases[a] || aliases[a].length > 80)
                return workflowError("Workflow " + input.id + " has an invalid alias");
        }
        var parameters = copyArray(input.parameters);
        if (parameters.length > 16) return workflowError("Workflow " + input.id + " has too many parameters");
        var parameterIds = {};
        var normalizedParameters = [];
        for (var p = 0; p < parameters.length; p++) {
            var parameter = parameters[p];
            if (!parameter || !stableId(parameter.name) || parameterIds[parameter.name]
                    || WORKFLOW_PARAMETER_TYPES.indexOf(parameter.type) < 0)
                return workflowError("Workflow " + input.id + " has an invalid parameter");
            parameterIds[parameter.name] = true;
            normalizedParameters.push({
                name: parameter.name,
                type: parameter.type,
                required: parameter.required !== false,
                values: copyArray(parameter.values).slice(0, 256)
            });
        }
        if (input.stopOnFailure === false)
            return workflowError("Workflow " + input.id + " must stop on required failure");
        var steps = copyArray(input.steps);
        if (steps.length === 0 || steps.length > WORKFLOW_MAX_STEPS)
            return workflowError("Workflow " + input.id + " requires 1-" + WORKFLOW_MAX_STEPS + " steps");
        var normalizedSteps = [];
        for (var s = 0; s < steps.length; s++) {
            var step = steps[s];
            if (!step || typeof step !== "object" || WORKFLOW_ACTIONS.indexOf(step.action) < 0)
                return workflowError("Workflow " + input.id + " has an unknown step action");
            if (step.argv !== undefined || step.command !== undefined || step.shell !== undefined)
                return workflowError("Workflow " + input.id + " step contains executable content");
            normalizedSteps.push({ action: step.action, optional: step.optional === true });
        }
        ids[input.id] = true;
        workflows.push({
            id: input.id,
            title: title,
            aliases: aliases,
            parameters: normalizedParameters,
            steps: normalizedSteps,
            stopOnFailure: true
        });
    }
    return workflowOk(workflows);
}

function findProject(projects, identity) {
    if (!Array.isArray(projects)) return null;
    for (var i = 0; i < projects.length; i++) {
        var project = projects[i];
        if (project && (project.id === identity || project.path === identity)) return project;
    }
    return null;
}

function planStep(step, project, capabilities) {
    var common = { id: step.action, title: step.action, optional: step.optional === true, project: project };
    if (step.action === "project.open-or-focus-editor") {
        common.title = "Open or focus editor";
        common.executor = "builtin";
        common.builtin = "projectEditor";
    } else if (step.action === "project.open-or-focus-terminal") {
        if (capabilities && capabilities.terminal === false) return common.optional ? null : workflowError("Terminal capability is unavailable");
        common.title = "Open or focus terminal";
        common.executor = "builtin";
        common.builtin = "projectTerminal";
        common.session = sessionName(project);
        common.tmux = !!(capabilities && capabilities.tmux);
    } else if (step.action === "project.open-git-remote") {
        if (!project.remote || (capabilities && capabilities.browser === false))
            return common.optional ? null : workflowError("Git remote capability is unavailable");
        common.title = "Open Git remote";
        common.executor = "argv";
        common.argv = ["xdg-open", project.remote];
    }
    return common;
}

function buildPlan(workflow, values, projects, capabilities) {
    var checked = validateConfig([workflow]);
    if (!checked.ok) return checked;
    var normalized = checked.value[0];
    values = values || {};
    var project = null;
    for (var p = 0; p < normalized.parameters.length; p++) {
        var parameter = normalized.parameters[p];
        if (parameter.required && (values[parameter.name] === undefined || values[parameter.name] === ""))
            return workflowError("Missing required parameter: " + parameter.name);
        if (parameter.type === "project" && values[parameter.name]) {
            project = findProject(projects, values[parameter.name]);
            if (!project) return workflowError("Project parameter was not found");
        }
    }
    if (!project && normalized.steps.length > 0) return workflowError("Workflow requires a project parameter");
    var validatedProject = validateProject(project);
    if (!validatedProject.ok) return validatedProject;
    var plan = [];
    for (var i = 0; i < normalized.steps.length; i++) {
        var resolved = planStep(normalized.steps[i], validatedProject.value, capabilities || {});
        if (resolved && resolved.ok === false) return resolved;
        if (resolved) plan.push(resolved);
    }
    if (plan.length === 0) return workflowError("Workflow has no available steps");
    return workflowOk({ workflowId: normalized.id, title: normalized.title, project: validatedProject.value, steps: plan });
}

function projectResume(project, options, capabilities) {
    options = options || {};
    var steps = [
        { action: "project.open-or-focus-editor" },
        { action: "project.open-or-focus-terminal" }
    ];
    if (options.openRemote === true)
        steps.push({ action: "project.open-git-remote", optional: true });
    var workflow = {
        id: "project.resume",
        title: "Resume " + String(project && project.name || "project"),
        aliases: [],
        parameters: [{ name: "project", type: "project", required: true }],
        steps: steps,
        stopOnFailure: true
    };
    return buildPlan(workflow, { project: project && (project.id || project.path) }, [project], capabilities || {});
}

function runtimeCopy(state) {
    return {
        token: state.token,
        plan: state.plan,
        index: state.index,
        statuses: state.statuses.map(function(status) {
            return { state: status.state, detail: status.detail };
        }),
        canceled: state.canceled,
        done: state.done,
        failed: state.failed
    };
}

function start(plan, token) {
    if (!plan || !Array.isArray(plan.steps) || plan.steps.length === 0 || plan.steps.length > WORKFLOW_MAX_STEPS)
        return workflowError("Invalid workflow plan");
    var runtimeToken = String(token || "");
    if (!runtimeToken) return workflowError("Workflow token is required");
    return workflowOk({
        token: runtimeToken,
        plan: plan,
        index: 0,
        statuses: plan.steps.map(function() { return { state: "pending", detail: "" }; }),
        canceled: false,
        done: false,
        failed: false
    });
}

function current(state) {
    if (!state || !state.plan || !Array.isArray(state.plan.steps)) return workflowError("Invalid workflow runtime");
    return workflowOk(state.done ? null : state.plan.steps[state.index]);
}

function checkRuntime(state, token) {
    if (!state || state.done || String(token || "") !== String(state.token)) return false;
    return state.index >= 0 && state.index < state.statuses.length;
}

function succeedStep(state, token, detail) {
    if (!checkRuntime(state, token)) return workflowError("Stale or completed workflow token");
    var next = runtimeCopy(state);
    next.statuses[next.index] = { state: "success", detail: String(detail || "") };
    next.index += 1;
    if (next.index >= next.plan.steps.length) next.done = true;
    return workflowOk(next);
}

function failStep(state, token, detail) {
    if (!checkRuntime(state, token)) return workflowError("Stale or completed workflow token");
    var next = runtimeCopy(state);
    var step = next.plan.steps[next.index];
    next.statuses[next.index] = { state: step.optional ? "optional-failure" : "failure", detail: String(detail || "") };
    next.index += 1;
    if (!step.optional) {
        next.failed = true;
        next.done = true;
    } else if (next.index >= next.plan.steps.length) next.done = true;
    return workflowOk(next);
}

function cancel(state, token) {
    if (!checkRuntime(state, token)) return workflowError("Stale or completed workflow token");
    var next = runtimeCopy(state);
    next.canceled = true;
    next.done = true;
    next.statuses[next.index] = { state: "canceled", detail: "Canceled" };
    return workflowOk(next);
}

if (typeof module !== "undefined") module.exports = {
    ACTIONS: WORKFLOW_ACTIONS,
    MAX_STEPS: WORKFLOW_MAX_STEPS,
    stableId: stableId,
    stableHash: stableHash,
    projectId: projectId,
    sessionName: sessionName,
    normalizeRemote: normalizeRemote,
    validateProject: validateProject,
    validateConfig: validateConfig,
    buildPlan: buildPlan,
    projectResume: projectResume,
    start: start,
    current: current,
    succeedStep: succeedStep,
    failStep: failStep,
    cancel: cancel
};

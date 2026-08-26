const test = require('node:test');
const assert = require('node:assert/strict');
const Workflows = require('../js/Workflows.js');

const project = {
  path: '/home/ryan/Code/omnibox',
  name: 'Omnibox',
  branch: 'main',
  remote: 'git@github.com:rmacy/omnibox.git'
};
project.id = Workflows.projectId(project.path);

const workflow = {
  id: 'project.daily',
  title: 'Resume project',
  aliases: ['daily'],
  parameters: [{ name: 'project', type: 'project', required: true }],
  steps: [
    { action: 'project.open-or-focus-editor' },
    { action: 'project.open-or-focus-terminal' },
    { action: 'project.open-git-remote', optional: true }
  ],
  stopOnFailure: true
};

test('creates stable project and session identities', () => {
  assert.equal(Workflows.projectId(project.path), project.id);
  assert.equal(Workflows.projectId('relative'), '');
  assert.equal(Workflows.projectId('/tmp/../secret'), '');
  assert.match(Workflows.sessionName(project), /^omnibox-omnibox-[a-f0-9]+$/);
  assert.equal(Workflows.sessionName(project), Workflows.sessionName({ ...project }));
  assert.ok(Workflows.sessionName({ path: '/tmp/x', name: '___' }).startsWith('omnibox-project-'));
});

test('normalizes safe HTTPS and SSH remotes and rejects credentials', () => {
  assert.equal(Workflows.normalizeRemote('git@github.com:rmacy/omnibox.git'), 'https://github.com/rmacy/omnibox');
  assert.equal(Workflows.normalizeRemote('ssh://git@github.com/rmacy/omnibox.git'), 'https://github.com/rmacy/omnibox');
  assert.equal(Workflows.normalizeRemote('https://github.com/rmacy/omnibox.git'), 'https://github.com/rmacy/omnibox');
  assert.equal(Workflows.normalizeRemote('https://user:secret@github.com/rmacy/omnibox'), '');
  assert.equal(Workflows.normalizeRemote('file:///tmp/repo'), '');
  assert.equal(Workflows.normalizeRemote(''), '');
});

test('validates and normalizes project metadata', () => {
  const checked = Workflows.validateProject(project);
  assert.equal(checked.ok, true, checked.error);
  assert.equal(checked.value.remote, 'https://github.com/rmacy/omnibox');
  assert.equal(checked.value.marker, '.git');
  assert.equal(checked.value.refreshedAt, 0);
  assert.equal(Workflows.validateProject(null).ok, false);
  assert.equal(Workflows.validateProject({ ...project, id: 'project:wrong' }).ok, false);
  assert.equal(Workflows.validateProject({ ...project, name: '' }).ok, true);
  assert.equal(Workflows.validateProject({ ...project, branch: 'bad\nbranch' }).ok, false);
  assert.equal(Workflows.validateProject({ ...project, marker: '.hg' }).ok, false);
  assert.equal(Workflows.validateProject({ ...project, remote: 'https://u:p@example.com/x' }).ok, false);
});

test('validates registered workflows and rejects executable content', () => {
  const checked = Workflows.validateConfig([workflow]);
  assert.equal(checked.ok, true, checked.error);
  assert.deepEqual(checked.value[0].steps.map(x => x.action), workflow.steps.map(x => x.action));
  assert.equal(Workflows.validateConfig(null).ok, false);
  assert.equal(Workflows.validateConfig(Array(65).fill(workflow)).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, id: 'bad id' }]).ok, false);
  assert.equal(Workflows.validateConfig([workflow, workflow]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, title: '' }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, aliases: Array(33).fill('a') }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, aliases: [7] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, parameters: [{ name: 'x', type: 'unknown' }] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, parameters: [
    { name: 'x', type: 'string' }, { name: 'x', type: 'string' }
  ] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, steps: [] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, steps: Array(33).fill(workflow.steps[0]) }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, steps: [{ action: 'shell.exec' }] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, command: 'rm -rf /' }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, stopOnFailure: false }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, steps: [{ ...workflow.steps[0], argv: ['bad'] }] }]).ok, false);
});

test('builds concrete registered plans and resolves project parameters', () => {
  const plan = Workflows.buildPlan(workflow, { project: project.id }, [project], {
    terminal: true, tmux: true, browser: true
  });
  assert.equal(plan.ok, true, plan.error);
  assert.deepEqual(plan.value.steps.map(x => x.builtin || x.argv[0]), [
    'projectEditor', 'projectTerminal', 'xdg-open'
  ]);
  assert.equal(plan.value.steps[1].tmux, true);
  assert.equal(plan.value.steps[1].session, Workflows.sessionName(project));
  assert.equal(plan.value.steps[2].argv[1], 'https://github.com/rmacy/omnibox');
  assert.equal(Workflows.buildPlan(workflow, {}, [project], {}).ok, false);
  assert.equal(Workflows.buildPlan(workflow, { project: 'missing' }, [project], {}).ok, false);
  assert.equal(Workflows.buildPlan(workflow, { project: project.id }, [project], { terminal: false }).ok, false);
});

test('skips unavailable optional capabilities and rejects required ones', () => {
  const optional = Workflows.buildPlan(workflow, { project: project.id }, [{ ...project, remote: '' }], {
    terminal: true, browser: false
  });
  assert.equal(optional.ok, true);
  assert.equal(optional.value.steps.length, 2);
  const requiredRemote = {
    ...workflow,
    steps: [{ action: 'project.open-git-remote', optional: false }]
  };
  assert.equal(Workflows.buildPlan(requiredRemote, { project: project.id }, [{ ...project, remote: '' }], {
    browser: false
  }).ok, false);
});

test('builds identical idempotent Project Resume plans', () => {
  const plans = Array.from({ length: 3 }, () => Workflows.projectResume(project, { openRemote: false }, {
    terminal: true, tmux: true, browser: true
  }).value);
  assert.deepEqual(plans[0], plans[1]);
  assert.deepEqual(plans[1], plans[2]);
  assert.equal(plans[0].workflowId, 'project.resume');
  assert.equal(plans[0].steps.length, 2);
  assert.equal(plans[0].steps[1].session, plans[1].steps[1].session);
});

test('executes runtime steps sequentially and immutably', () => {
  const plan = Workflows.projectResume(project, { openRemote: true }, {
    terminal: true, tmux: true, browser: true
  }).value;
  const started = Workflows.start(plan, 'token-1');
  assert.equal(started.ok, true);
  const initial = structuredClone(started.value);
  assert.equal(Workflows.current(started.value).value.id, 'project.open-or-focus-editor');
  const first = Workflows.succeedStep(started.value, 'token-1', 'focused');
  assert.equal(first.value.index, 1);
  assert.equal(first.value.statuses[0].state, 'success');
  assert.deepEqual(started.value, initial);
  assert.equal(Workflows.succeedStep(started.value, 'stale', '').ok, false);
  let state = first.value;
  state = Workflows.succeedStep(state, 'token-1', 'attached').value;
  state = Workflows.failStep(state, 'token-1', 'no remote').value;
  assert.equal(state.done, true);
  assert.equal(state.failed, false);
  assert.equal(state.statuses[2].state, 'optional-failure');
  assert.equal(Workflows.current(state).value, null);
});

test('stops required failures and supports cancellation', () => {
  const plan = Workflows.projectResume(project, { openRemote: false }, {
    terminal: true, tmux: false, browser: true
  }).value;
  const started = Workflows.start(plan, 'token-2').value;
  const failed = Workflows.failStep(started, 'token-2', 'editor failed').value;
  assert.equal(failed.done, true);
  assert.equal(failed.failed, true);
  assert.equal(failed.statuses[0].state, 'failure');
  assert.equal(Workflows.succeedStep(failed, 'token-2', '').ok, false);

  const another = Workflows.start(plan, 'token-3').value;
  const canceled = Workflows.cancel(another, 'token-3').value;
  assert.equal(canceled.canceled, true);
  assert.equal(canceled.done, true);
  assert.equal(canceled.statuses[0].state, 'canceled');
  assert.equal(Workflows.cancel(another, 'stale').ok, false);
  assert.equal(Workflows.start({}, 'x').ok, false);
  assert.equal(Workflows.start(plan, '').ok, false);
  assert.equal(Workflows.current(null).ok, false);
});

test('covers remaining validation and runtime boundaries', () => {
  assert.equal(Workflows.stableId(7), false);
  assert.equal(Workflows.stableId('_bad'), false);
  assert.equal(Workflows.projectId(`${project.path}/`), project.id);
  assert.equal(Workflows.projectId(`/tmp/${'x'.repeat(5000)}`), '');
  assert.equal(Workflows.projectId('/tmp/a\u0000b'), '');
  assert.equal(Workflows.normalizeRemote('https://git.example.com/team/repo.git'),
    'https://git.example.com/team/repo');
  assert.equal(Workflows.normalizeRemote('bad\u0000remote'), '');

  assert.equal(Workflows.validateConfig([[]]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, argv: [] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, shell: 'bad' }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, title: 'x'.repeat(257) }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, aliases: [''] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, aliases: ['x'.repeat(81)] }]).ok, false);
  assert.equal(Workflows.validateConfig([{
    ...workflow, parameters: Array.from({ length: 17 }, (_, i) => ({ name: `p${i}`, type: 'string' }))
  }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, parameters: [null] }]).ok, false);
  assert.equal(Workflows.validateConfig([{ ...workflow, steps: [null] }]).ok, false);
  assert.equal(Workflows.validateConfig([{
    ...workflow, steps: [{ action: 'project.open-or-focus-editor', command: 'bad' }]
  }]).ok, false);

  const optionalParameter = Workflows.validateConfig([{
    ...workflow,
    parameters: [{ name: 'project', type: 'project', required: false, values: [project.id] }]
  }]).value[0].parameters[0];
  assert.equal(optionalParameter.required, false);
  assert.deepEqual(optionalParameter.values, [project.id]);

  assert.equal(Workflows.buildPlan(workflow, { project: project.id }, null, {}).ok, false);
  const onlyOptionalTerminal = {
    ...workflow,
    steps: [{ action: 'project.open-or-focus-terminal', optional: true }]
  };
  assert.match(Workflows.buildPlan(onlyOptionalTerminal, { project: project.id }, [project], {
    terminal: false
  }).error, /no available steps/);
  const noTmux = Workflows.buildPlan({
    ...workflow, steps: [{ action: 'project.open-or-focus-terminal' }]
  }, { project: project.path }, [project], {}).value;
  assert.equal(noTmux.steps[0].tmux, false);
  assert.equal(Workflows.projectResume(null, {}, {}).ok, false);

  assert.equal(Workflows.start({ steps: Array(33).fill({}) }, 'token').ok, false);
  const tinyPlan = { steps: [{ id: 'one', optional: false }] };
  let runtime = Workflows.start(tinyPlan, 42).value;
  assert.equal(runtime.token, '42');
  runtime = Workflows.succeedStep(runtime, '42', '').value;
  assert.equal(runtime.done, true);
  assert.equal(Workflows.current(runtime).value, null);
  const invalidIndex = Workflows.start(tinyPlan, 'bad-index').value;
  invalidIndex.index = 9;
  assert.equal(Workflows.cancel(invalidIndex, 'bad-index').ok, false);
});

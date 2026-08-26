const test = require('node:test');
const assert = require('node:assert/strict');
const fixtures = require('./fixtures/current-results.json');
const Actions = require('../js/Actions.js');

test('records all ten current source behaviors as valid typed results', () => {
  assert.deepEqual(fixtures.map(x => x.source), [
    'calc', 'apps', 'windows', 'files', 'clipboard',
    'system', 'web', 'ssh', 'run', 'providers'
  ]);
  for (const fixture of fixtures) {
    const checked = Actions.validateResult(fixture);
    assert.equal(checked.ok, true, checked.error);
    const primary = Actions.primaryAction(fixture);
    assert.equal(primary.ok, true);
    assert.equal(primary.value.id, fixture.actions[0].id);
  }
});

test('validates identifiers, types, source, titles, and action presence', () => {
  const base = fixtures[0];
  assert.match(Actions.validateResult({ ...base, id: 'bad id' }).error, /invalid id/);
  assert.match(Actions.validateResult({ ...base, type: 'unknown' }).error, /invalid type/);
  assert.match(Actions.validateResult({ ...base, source: '_bad' }).error, /invalid source/);
  assert.match(Actions.validateResult({ ...base, title: '' }).error, /must not be empty/);
  assert.match(Actions.validateResult({ ...base, actions: [] }).error, /at least one/);
  assert.match(Actions.validateResult(null).error, /object/);
  assert.equal(Actions.stableId('file:/tmp/a-b.txt'), true);
  assert.equal(Actions.stableId(''), false);
});

test('keeps shell metacharacters literal in argv', () => {
  const argv = ['printf', '%s', '$(touch /tmp/no); `id`\n--leading'];
  const checked = Actions.validateArgv(argv);
  assert.equal(checked.ok, true);
  assert.deepEqual(checked.value, argv);
});

test('enforces argv count, type, and byte bounds', () => {
  assert.equal(Actions.validateArgv([]).ok, false);
  assert.equal(Actions.validateArgv(Array(65).fill('x')).ok, false);
  assert.equal(Actions.validateArgv(['ok', 7]).ok, false);
  assert.equal(Actions.validateArgv(['x'.repeat(16385)]).ok, false);
  assert.equal(Actions.utf8Bytes('abc'), 3);
  assert.equal(Actions.utf8Bytes('é'), 2);
  assert.equal(Actions.utf8Bytes('😀'), 4);
});

test('enforces executor-specific fields and shell trust', () => {
  const common = { id: 'test.action', title: 'Test', lifecycle: 'close', risk: 'safe' };
  assert.match(Actions.validateAction({ ...common, executor: 'argv', argv: [] }).error, /argv/);
  assert.match(Actions.validateAction({ ...common, executor: 'builtin' }).error, /builtin/);
  assert.match(Actions.validateAction({ ...common, executor: 'next', next: {} }).error, /next/);
  assert.match(Actions.validateAction({ ...common, executor: 'workflow' }).error, /workflowId/);
  assert.match(Actions.validateAction({ ...common, executor: 'shell', command: 'echo ok' }).error, /trusted/);
  assert.equal(Actions.validateAction({
    ...common, executor: 'shell', command: 'echo ok', trusted: true
  }).ok, true);
  assert.match(Actions.validateAction({ ...common, executor: 'nope' }).error, /executor/);
});

test('requires confirmation for destructive actions', () => {
  const action = {
    id: 'window.close', title: 'Close', executor: 'builtin', builtin: 'windowClose',
    lifecycle: 'close', risk: 'destructive'
  };
  assert.match(Actions.validateAction(action).error, /requires confirm/);
  assert.equal(Actions.validateAction({ ...action, confirm: true }).ok, true);
});

test('rejects lifecycle conflicts and invalid enums', () => {
  const action = {
    id: 'x', title: 'X', executor: 'builtin', builtin: 'copyText', lifecycle: 'close', risk: 'safe'
  };
  assert.match(Actions.validateAction({ ...action, keepOpen: true }).error, /lifecycle/);
  assert.match(Actions.validateAction({ ...action, lifecycle: 'forever' }).error, /lifecycle/);
  assert.match(Actions.validateAction({ ...action, risk: 'invisible' }).error, /risk/);
  assert.match(Actions.validateAction({ ...action, title: '' }).error, /title/);
});

test('validates typed argument fields', () => {
  const common = {
    id: 'x', title: 'X', executor: 'builtin', builtin: 'pick', lifecycle: 'keepOpen', risk: 'safe'
  };
  const checked = Actions.validateAction({
    ...common,
    arguments: [{ id: 'workspace', type: 'workspace', title: 'Workspace', values: ['1', '2'] }]
  });
  assert.equal(checked.ok, true);
  assert.deepEqual(checked.value.arguments[0].values, ['1', '2']);
  assert.match(Actions.validateAction({ ...common, arguments: [{}] }).error, /invalid id/);
  assert.match(Actions.validateAction({
    ...common, arguments: [{ id: 'a', type: 'enum' }, { id: 'a', type: 'enum' }]
  }).error, /duplicate/);
  assert.match(Actions.validateAction({
    ...common, arguments: [{ id: 'a', type: 'unknown' }]
  }).error, /invalid type/);
});

test('rejects too many and duplicate actions', () => {
  const baseAction = fixtures[0].actions[0];
  assert.match(Actions.validateResult({
    ...fixtures[0], actions: Array(33).fill(baseAction)
  }).error, /exceeds/);
  assert.match(Actions.validateResult({
    ...fixtures[0], actions: [baseAction, baseAction]
  }).error, /duplicate action/);
});

test('make functions do not mutate caller objects', () => {
  const input = structuredClone(fixtures[3]);
  const before = structuredClone(input);
  const made = Actions.makeResult(input);
  assert.equal(made.ok, true);
  made.value.actions[0].argv[1] = '/changed';
  assert.deepEqual(input, before);
  const action = Actions.makeAction(fixtures[0].actions[0]);
  assert.equal(action.ok, true);
  assert.notEqual(action.value, fixtures[0].actions[0]);
});

test('primaryAction reports invalid results', () => {
  assert.equal(Actions.primaryAction({}).ok, false);
});

test('accepts every executor and lifecycle with normalized output', () => {
  const actions = [
    { id: 'a.argv', title: 'Argv', subtitle: 'detail', executor: 'argv', argv: ['true'], lifecycle: 'keepOpen', risk: 'privileged' },
    { id: 'a.builtin', title: 'Builtin', executor: 'builtin', builtin: 'copyText', lifecycle: 'close', risk: 'safe' },
    { id: 'a.next', title: 'Next', executor: 'next', next: { type: 'device' }, lifecycle: 'keepOpen', risk: 'remote' },
    { id: 'a.workflow', title: 'Workflow', executor: 'workflow', workflowId: 'workflow:resume', lifecycle: 'keepOpen', risk: 'caution' },
    { id: 'a.shell', title: 'Shell', executor: 'shell', command: 'true', trusted: true, lifecycle: 'terminal', risk: 'caution' }
  ];
  for (const spec of actions) assert.equal(Actions.makeAction(spec).ok, true);
  const next = Actions.makeAction(actions[2]).value;
  assert.deepEqual(next.next, { type: 'device' });
  assert.equal(Actions.makeAction(actions[3]).value.workflowId, 'workflow:resume');
  assert.equal(Actions.makeAction(actions[0]).value.subtitle, 'detail');
});

test('covers optional result fields and their deterministic defaults', () => {
  const made = Actions.makeResult({
    id: 'diagnostic:test',
    type: 'diagnostic',
    source: 'diagnostics',
    title: 'Diagnostic',
    icon: 7,
    appIcon: null,
    value: undefined,
    matchScore: Number.NaN,
    aliases: 'not-an-array',
    actions: [{ id: 'diagnostic.dismiss', title: 'Dismiss', executor: 'builtin', builtin: 'dismiss' }]
  });
  assert.equal(made.ok, true);
  assert.equal(made.value.subtitle, '');
  assert.equal(made.value.icon, '');
  assert.equal(made.value.appIcon, '');
  assert.equal(made.value.value, null);
  assert.equal(made.value.matchScore, 0);
  assert.deepEqual(made.value.aliases, []);
  assert.equal(made.value.actions[0].lifecycle, 'close');
  assert.equal(made.value.actions[0].risk, 'safe');
});

test('rejects remaining malformed action and argument boundaries', () => {
  assert.equal(Actions.validateAction(null).ok, false);
  assert.match(Actions.validateAction({ id: '_bad', title: 'Bad', executor: 'builtin', builtin: 'x' }).error, /invalid id/);
  assert.match(Actions.validateAction({ id: 'x', title: 7, executor: 'builtin', builtin: 'x' }).error, /title/);
  assert.match(Actions.validateAction({
    id: 'x', title: 'X', executor: 'shell', command: '', trusted: true
  }).error, /must not be empty/);
  assert.match(Actions.validateAction({
    id: 'x', title: 'X', executor: 'builtin', builtin: 'x', arguments: 'bad'
  }).error, /arguments/);
  assert.match(Actions.validateAction({
    id: 'x', title: 'X', executor: 'builtin', builtin: 'x',
    arguments: Array.from({ length: 17 }, (_, i) => ({ id: `a${i}`, type: 'string' }))
  }).error, /at most 16/);
  const optional = Actions.validateAction({
    id: 'x', title: 'X', executor: 'builtin', builtin: 'x',
    arguments: [{ id: 'name', type: 'string', required: false, values: 'not-array' }]
  });
  assert.equal(optional.value.arguments[0].required, false);
  assert.deepEqual(optional.value.arguments[0].values, []);
  assert.equal(Actions.validateResult({
    ...fixtures[0], subtitle: 'x'.repeat(16385)
  }).ok, false);
});

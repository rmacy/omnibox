const test = require('node:test');
const assert = require('node:assert/strict');
const Metrics = require('../js/Metrics.js');

test('creates the fixed aggregate-only schema', () => {
  const state = Metrics.create();
  assert.equal(state.version, 1);
  assert.deepEqual(Object.keys(state.counters), Metrics.COUNTERS);
  assert.deepEqual(state.sources, {});
  assert.deepEqual(state.actions, {});
  assert.deepEqual(Object.keys(state.latency), ['render', 'async', 'completion']);
});

test('sanitizes unknown keys and nonnumeric or excessive counts', () => {
  const sanitized = Metrics.sanitize({
    version: 1,
    query: 'secret',
    counters: { opens: 4.9, unknown: 7, failures: -1, successes: Infinity },
    sources: { apps: 2, secretSource: 9 },
    types: { file: 3, unknown: 4 },
    actions: { 'apps/app.open': 2, 'providers/file.secret': 5, 'bad id': 6 },
    latency: { render: { lt50: 2, secret: 4 }, bad: { lt50: 9 } },
    workflows: { runs: 2, steps: 99999999999, rawArguments: 4 }
  });
  assert.equal(sanitized.counters.opens, 4);
  assert.equal(sanitized.counters.failures, 0);
  assert.equal(sanitized.counters.successes, 0);
  assert.equal(Object.hasOwn(sanitized, 'query'), false);
  assert.deepEqual(sanitized.sources, { apps: 2 });
  assert.deepEqual(sanitized.types, { file: 3 });
  assert.deepEqual(sanitized.actions, { 'apps/app.open': 2 });
  assert.equal(sanitized.latency.render.lt50, 2);
  assert.equal(sanitized.workflows.steps, 1_000_000_000);
  assert.equal(Object.hasOwn(sanitized.workflows, 'rawArguments'), false);
  assert.deepEqual(Metrics.sanitize(null), Metrics.create());
  assert.deepEqual(Metrics.sanitize({ version: 2 }), Metrics.create());
});

test('increments only allowlisted events immutably', () => {
  const state = Metrics.create();
  const opened = Metrics.increment(state, 'opens');
  const moved = Metrics.increment(opened, 'selectionMoves', 3);
  const ignored = Metrics.increment(moved, 'queryText', 99);
  assert.equal(opened.counters.opens, 1);
  assert.equal(moved.counters.selectionMoves, 3);
  assert.equal(Object.hasOwn(ignored.counters, 'queryText'), false);
  assert.equal(state.counters.opens, 0);
});

test('records first-party aggregate activation dimensions only', () => {
  let state = Metrics.recordActivation(Metrics.create(),
    { source: 'files', type: 'file', title: 'secret path' },
    { id: 'file.copy-path', argv: ['/private/path'] }, true);
  assert.equal(state.counters.activations, 1);
  assert.equal(state.counters.secondaryActions, 1);
  assert.equal(state.sources.files, 1);
  assert.equal(state.types.file, 1);
  assert.equal(state.actions['files/file.copy-path'], 1);
  assert.equal(JSON.stringify(state).includes('secret path'), false);
  assert.equal(JSON.stringify(state).includes('/private/path'), false);

  state = Metrics.recordActivation(state,
    { source: 'providers', type: 'provider' }, { id: 'provider.exfiltrate' }, false);
  assert.equal(state.sources.providers, 1);
  assert.equal(Object.hasOwn(state.actions, 'provider.exfiltrate'), false);
});

test('buckets bounded latency without recording raw values', () => {
  assert.equal(Metrics.latencyBucket(0), 'lt50');
  assert.equal(Metrics.latencyBucket(49), 'lt50');
  assert.equal(Metrics.latencyBucket(50), '50to199');
  assert.equal(Metrics.latencyBucket(199), '50to199');
  assert.equal(Metrics.latencyBucket(200), '200to999');
  assert.equal(Metrics.latencyBucket(999), '200to999');
  assert.equal(Metrics.latencyBucket(1000), 'gte1000');
  assert.equal(Metrics.latencyBucket(-1), '');
  assert.equal(Metrics.latencyBucket(NaN), '');
  let state = Metrics.recordLatency(Metrics.create(), 'render', 12.3);
  state = Metrics.recordLatency(state, 'unknown', 12);
  state = Metrics.recordLatency(state, 'completion', -1);
  assert.equal(state.latency.render.lt50, 1);
  assert.equal(Object.hasOwn(state.latency, 'unknown'), false);
  assert.equal(Object.values(state.latency.completion).reduce((a, b) => a + b, 0), 0);
});

test('records workflow counts and exposes a content-free summary', () => {
  let state = Metrics.recordWorkflow(Metrics.create(), 4, 'success');
  state = Metrics.recordWorkflow(state, 2, 'failure');
  state = Metrics.recordWorkflow(state, 1, 'canceled');
  state = Metrics.recordWorkflow(state, 1, 'unknown');
  assert.deepEqual(state.workflows, {
    runs: 4, successes: 1, failures: 1, cancellations: 1, steps: 8
  });
  assert.deepEqual(Metrics.summary(state), {
    opens: 0, activations: 0, secondaryActions: 0, successes: 0, failures: 0, workflows: 4
  });
});

test('validates action ID allowlist', () => {
  const allowed = [
    ['apps', 'app.open'], ['windows', 'window.close'], ['files', 'file.copy-path'],
    ['calc', 'calculation.copy'], ['web', 'web.open'], ['clipboard', 'clipboard.paste'],
    ['ssh', 'ssh.connect'], ['system', 'system.lock'], ['apps', 'learning.pin'],
    ['native', 'native.run'], ['projects', 'project.resume'], ['workflows', 'workflow.run']
  ];
  for (const [source, id] of allowed)
    assert.equal(Metrics.allowedActionId(source, id), true, `${source}/${id}`);
  for (const [source, id] of [
    ['providers', 'file.secret'], ['run', 'shell.run'], ['apps', 'bad id'], ['', 'app.open']
  ]) assert.equal(Metrics.allowedActionId(source, id), false, `${source}/${id}`);
  assert.equal(Metrics.allowedActionKey('files/file.open'), true);
  assert.equal(Metrics.allowedActionKey('providers/file.secret'), false);
});

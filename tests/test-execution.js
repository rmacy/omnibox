const test = require('node:test');
const assert = require('node:assert/strict');
const Execution = require('../js/Execution.js');

test('keeps safe argv literal and immutable', () => {
  const action = { argv: ['printf', '%s', '$(touch /tmp/no); --value'], lifecycle: 'close', risk: 'safe' };
  const before = structuredClone(action);
  assert.deepEqual(Execution.argvFor(action), action.argv);
  assert.deepEqual(action, before);
});

test('routes privileged and terminal actions through visible terminals', () => {
  assert.deepEqual(Execution.argvFor({
    argv: ['omarchy', 'pkg', 'add', 'jq'], lifecycle: 'terminal', risk: 'privileged'
  }), ['xdg-terminal-exec', '--', 'sudo', '--', 'omarchy', 'pkg', 'add', 'jq']);
  assert.deepEqual(Execution.argvFor({
    argv: ['ssh', 'host'], lifecycle: 'terminal', risk: 'remote'
  }), ['xdg-terminal-exec', '--', 'ssh', 'host']);
  assert.deepEqual(Execution.argvFor({
    argv: ['xdg-terminal-exec', '--', 'ssh', 'host'], lifecycle: 'terminal', risk: 'remote'
  }), ['xdg-terminal-exec', '--', 'ssh', 'host']);
  assert.deepEqual(Execution.argvFor(null), []);
});

test('requires confirmation for explicit and destructive actions', () => {
  assert.equal(Execution.requiresConfirmation({ risk: 'destructive' }), true);
  assert.equal(Execution.requiresConfirmation({ risk: 'safe', confirm: true }), true);
  assert.equal(Execution.requiresConfirmation({ risk: 'safe' }), false);
  assert.equal(Execution.requiresConfirmation(null), false);
});

test('bounds captured output and normalizes invalid limits', () => {
  assert.equal(Execution.boundedAppend('abc', 'def', 5), 'abcde');
  assert.equal(Execution.boundedAppend('abcdef', 'x', 5), 'abcde');
  assert.equal(Execution.boundedAppend(null, null, -1), '');
  assert.equal(Execution.boundedAppend('', 'abc', Number.NaN), '');
});

test('redacts shell plans and truncates oversized argv display', () => {
  assert.deepEqual(Execution.redactedPlan({ executor: 'shell', command: 'secret' }), ['trusted shell action']);
  const plan = Execution.redactedPlan({
    executor: 'argv', argv: ['echo', 'x'.repeat(200)], lifecycle: 'close', risk: 'safe'
  });
  assert.equal(plan[0], 'echo');
  assert.equal(plan[1].length, 160);
  assert.match(plan[1], /\.\.\.$/);
});

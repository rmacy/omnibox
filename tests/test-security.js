const test = require('node:test');
const assert = require('node:assert/strict');
const Actions = require('../js/Actions.js');
const Execution = require('../js/Execution.js');
const Metrics = require('../js/Metrics.js');
const Native = require('../js/Native.js');
const Provider = require('../js/Provider.js');
const Workflows = require('../js/Workflows.js');

test('metacharacters remain literal across every typed argv boundary', () => {
  const values = [
    '$(touch /tmp/no)', '`id`', "a'b\"c", 'semi;colon', 'new\nline',
    '--leading', 'snowman-☃', 'x'.repeat(4096)
  ];
  for (const value of values) {
    const action = Actions.makeAction({
      id: 'security.literal', title: 'Literal', executor: 'argv',
      argv: ['printf', '%s', value], lifecycle: 'close', risk: 'safe'
    });
    assert.equal(action.ok, true, value);
    assert.equal(Execution.argvFor(action.value)[2], value);
  }
  const reminder = Native.intentRows('remind 10 $(touch /tmp/no);', {})[0];
  assert.equal(reminder.argv[3], '$(touch /tmp/no);');
  assert.deepEqual(Native.parseWords("'$(touch /tmp/no)' \"semi;colon\"").value,
    ['$(touch /tmp/no)', 'semi;colon']);
});

test('every producer is subordinate to core destructive confirmation', () => {
  assert.equal(Actions.makeAction({
    id: 'window.close', title: 'Close', executor: 'builtin', builtin: 'windowClose',
    lifecycle: 'close', risk: 'destructive'
  }).ok, false);
  assert.equal(Execution.requiresConfirmation({ risk: 'destructive', confirm: false }), true);
  assert.equal(Native.classify({
    route: 'omarchy system shutdown', group: 'system', requires_sudo: false
  }).confirm, true);
  const refreshPacman = Native.classify({
    route: 'omarchy refresh pacman', group: 'refresh', requires_sudo: true
  });
  assert.equal(refreshPacman.risk, 'destructive');
  assert.equal(refreshPacman.confirm, true);
  const snapshotRestore = Native.classifyResolved({
    route: 'omarchy snapshot', group: 'snapshot', requires_sudo: true
  }, ['omarchy', 'snapshot', 'restore']);
  assert.equal(snapshotRestore.risk, 'destructive');
  assert.equal(snapshotRestore.confirm, true);
  assert.equal(Provider.validateResult('security', {
    protocol: 2, id: 'row', title: 'Row', actions: [{
      id: 'delete', title: 'Delete', executor: 'argv', argv: ['rm', 'file'],
      lifecycle: 'terminal', risk: 'destructive', confirm: false
    }]
  }).ok, false);
  const mislabeled = Provider.validateAction({
    id: 'delete', title: 'Delete', executor: 'argv', argv: ['rm', '--', 'file'],
    lifecycle: 'close', risk: 'safe'
  }).value;
  assert.equal(mislabeled.risk, 'destructive');
  assert.equal(mislabeled.confirm, true);
  const opaqueWrapper = Provider.validateAction({
    id: 'wrapped-delete', title: 'Wrapped delete', executor: 'argv',
    argv: ['timeout', '5', 'sudo', 'rm', '-rf', 'file'],
    lifecycle: 'close', risk: 'safe'
  });
  assert.equal(opaqueWrapper.ok, false);
});

test('privilege always uses a visible terminal independent of safety', () => {
  const argv = Execution.argvFor({
    argv: ['omarchy', 'update'], lifecycle: 'terminal', risk: 'privileged'
  });
  assert.deepEqual(argv, ['xdg-terminal-exec', '--', 'omarchy', 'update']);
  const harmlessSudo = Native.classify({
    route: 'omarchy harmless status', group: 'status', requires_sudo: true
  });
  assert.equal(harmlessSudo.lifecycle, 'terminal');
  assert.equal(harmlessSudo.confirm, false);
});

test('provider trigger and context policy prevents ambient exfiltration', () => {
  const manifest = Provider.validateManifest({
    protocol: 2, id: 'security.provider', executable: 'run', enabled: true,
    queryPolicy: 'triggered', triggers: ['safe'], context: ['workspace']
  }, '/tmp/providers', []).value;
  assert.equal(Provider.triggerMatch(manifest, 'private unrelated query'), false);
  assert.deepEqual(Provider.filterContext(manifest, {
    workspace: '2', clipboard: 'secret', fileContents: 'secret', focusedWindowTitle: 'private'
  }), { workspace: '2' });
  assert.equal(Provider.validateManifest({
    protocol: 2, id: 'security.all', executable: 'run', enabled: true,
    queryPolicy: 'unrestricted', triggers: [], context: []
  }, '/tmp/providers', []).ok, false);
});

test('workflows reject executable configuration and credential-bearing remotes', () => {
  const workflow = {
    id: 'security.workflow', title: 'Security', aliases: [],
    parameters: [{ name: 'project', type: 'project', required: true }],
    steps: [{ action: 'project.open-or-focus-editor' }], stopOnFailure: true
  };
  assert.equal(Workflows.validateConfig([{ ...workflow, command: 'rm -rf /' }]).ok, false);
  assert.equal(Workflows.validateConfig([{
    ...workflow, steps: [{ action: 'project.open-or-focus-editor', shell: 'bad' }]
  }]).ok, false);
  assert.equal(Workflows.normalizeRemote('https://user:password@example.com/org/repo'), '');
});

test('metrics remove content even when callers provide it', () => {
  const state = Metrics.recordActivation(Metrics.create(), {
    source: 'files', type: 'file', title: '/private/path', query: 'secret'
  }, {
    id: 'file.open', argv: ['xdg-open', '/private/path'], output: 'secret stdout'
  }, false);
  const serialized = JSON.stringify(state);
  for (const forbidden of ['/private/path', 'secret', 'xdg-open'])
    assert.equal(serialized.includes(forbidden), false, forbidden);
  const providerState = Metrics.recordActivation(Metrics.create(), {
    source: 'providers', type: 'file'
  }, { id: 'file.confidential-name' }, false);
  assert.deepEqual(providerState.actions, {});
});

const test = require('node:test');
const assert = require('node:assert/strict');
const Provider = require('../js/Provider.js');

const manifest = {
  protocol: 2,
  id: 'example.packages',
  title: 'Packages',
  executable: 'packages',
  enabled: true,
  queryPolicy: 'triggered',
  triggers: ['pkg', 'package'],
  context: ['workspace'],
  capabilities: ['query'],
  timeoutMs: 900,
  killAfterMs: 200,
  maxRows: 8,
  maxLineBytes: 16384
};

const result = {
  protocol: 2,
  id: 'package:jq',
  type: 'provider',
  title: 'jq',
  subtitle: '1.8.1 · installed',
  icon: '󰣇',
  value: { package: 'jq' },
  actions: [{
    id: 'package.info', title: 'Package info', executor: 'argv',
    argv: ['xdg-terminal-exec', '--hold', '--', 'pacman', '-Qi', '--', 'jq'],
    lifecycle: 'close', risk: 'safe'
  }]
};

test('validates triggered and explicitly allowlisted unrestricted manifests', () => {
  const checked = Provider.validateManifest(manifest, '/plugin/providers', []);
  assert.equal(checked.ok, true, checked.error);
  assert.equal(checked.value.executablePath, '/plugin/providers/packages');
  assert.deepEqual(checked.value.triggers, ['pkg', 'package']);
  const unrestricted = Provider.validateManifest({
    ...manifest, id: 'example.all', queryPolicy: 'unrestricted', triggers: []
  }, '/user/providers/', ['example.all']);
  assert.equal(unrestricted.ok, true);
  assert.equal(unrestricted.value.sourceDir, '/user/providers');
  assert.equal(Provider.validateManifest({
    ...manifest, id: 'example.all', queryPolicy: 'unrestricted', triggers: []
  }, '/user/providers', []).ok, false);
});

test('rejects malformed manifests and clamps resource policy', () => {
  assert.equal(Provider.validateManifest(null, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, protocol: 1 }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, id: 'bad:id' }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, enabled: false }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, executable: '../bad' }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, queryPolicy: 'all' }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, triggers: [] }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, triggers: ['bad$'] }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, context: ['clipboard'] }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, context: ['workspace', 'workspace'] }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest(manifest, 'relative', []).ok, false);
  const clamped = Provider.validateManifest({
    ...manifest, timeoutMs: 99999, killAfterMs: 0, maxRows: 99, maxLineBytes: 1
  }, '/x', []).value;
  assert.deepEqual([clamped.timeoutMs, clamped.killAfterMs, clamped.maxRows, clamped.maxLineBytes],
    [5000, 50, 32, 256]);
});

test('matches explicit triggers and strips only matched trigger text', () => {
  const checked = Provider.validateManifest(manifest, '/x', []).value;
  assert.equal(Provider.triggerMatch(checked, 'pkg jq'), true);
  assert.equal(Provider.triggerMatch(checked, 'PACKAGE: bat'), true);
  assert.equal(Provider.triggerMatch(checked, 'packages'), false);
  assert.equal(Provider.triggerMatch(checked, 'unrelated'), false);
  assert.equal(Provider.queryBody(checked, 'pkg jq'), 'jq');
  assert.equal(Provider.queryBody(checked, 'package:  bat'), 'bat');
  assert.equal(Provider.queryBody(checked, 'pkg'), '');
  assert.equal(Provider.queryBody(checked, 'unrelated'), 'unrelated');
  assert.equal(Provider.triggerMatch({ queryPolicy: 'unrestricted' }, 'anything'), true);
  assert.equal(Provider.queryBody({ queryPolicy: 'unrestricted' }, ' anything '), 'anything');
});

test('passes only explicitly requested bounded context', () => {
  const checked = Provider.validateManifest(manifest, '/x', []).value;
  const filtered = Provider.filterContext(checked, {
    workspace: '3', clipboard: 'secret', focusedWindowTitle: 'private', monitor: 'DP-1'
  });
  assert.deepEqual(filtered, { workspace: '3' });
  assert.deepEqual(Provider.filterContext(null, { workspace: '3' }), {});
  const long = Provider.filterContext({ context: ['workspace'] }, { workspace: 'x'.repeat(1000) });
  assert.equal(long.workspace.length, 512);
});

test('validates namespaced typed results and preserves literal argv', () => {
  const checked = Provider.validateResult('example.packages', result);
  assert.equal(checked.ok, true, checked.error);
  assert.equal(checked.value.id, 'provider:example.packages:package:jq');
  assert.equal(checked.value.provenance, 'example.packages');
  assert.deepEqual(checked.value.actions[0].argv, result.actions[0].argv);
  const literal = Provider.validateResult('example.packages', {
    ...result,
    id: 'literal',
    actions: [{ ...result.actions[0], argv: ['printf', '%s', '$(touch /tmp/no);'] }]
  });
  assert.equal(literal.ok, true);
  assert.equal(literal.value.actions[0].argv[2], '$(touch /tmp/no);');
});

test('rejects collisions, shell actions, malformed policies, and oversized results', () => {
  assert.equal(Provider.validateResult('bad:id', result).ok, false);
  assert.equal(Provider.validateResult('example', null).ok, false);
  assert.equal(Provider.validateResult('example', { ...result, protocol: 1 }).ok, false);
  assert.equal(Provider.validateResult('example', { ...result, id: 'bad id' }).ok, false);
  assert.equal(Provider.validateResult('example', { ...result, type: 'app' }).ok, false);
  assert.equal(Provider.validateResult('example', { ...result, title: '' }).ok, false);
  assert.equal(Provider.validateResult('example', { ...result, actions: [] }).ok, false);
  assert.equal(Provider.validateResult('example', {
    ...result, actions: [{ ...result.actions[0], executor: 'shell', command: 'bad' }]
  }).ok, false);
  assert.equal(Provider.validateResult('example', {
    ...result, actions: [{ ...result.actions[0], risk: 'destructive', confirm: false }]
  }).ok, false);
  assert.equal(Provider.validateResult('example', {
    ...result, actions: [result.actions[0], result.actions[0]]
  }).ok, false);
  assert.equal(Provider.validateResult('example', { ...result, value: 'x'.repeat(70000) }).ok, false);
});

test('accepts confirmed destructive and terminal provider argv actions', () => {
  const checked = Provider.validateResult('example', {
    ...result,
    actions: [{
      id: 'package.remove', title: 'Remove', executor: 'argv', argv: ['omarchy', 'pkg', 'drop', 'jq'],
      risk: 'destructive', lifecycle: 'terminal', confirm: true
    }]
  });
  assert.equal(checked.ok, true);
  assert.equal(checked.value.actions[0].confirm, true);
});

test('covers manifest defaults, fallback bounds, and remaining rejection branches', () => {
  assert.equal(Provider.validateManifest([], '/x', []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, executable: 7 }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest(manifest, `/x\u0000bad`, []).ok, false);
  assert.equal(Provider.validateManifest({ ...manifest, triggers: Array(17).fill('x') }, '/x', []).ok, false);
  assert.equal(Provider.validateManifest({
    ...manifest, context: ['workspace', 'monitor', 'time', 'focusedWindowClass', 'focusedWindowTitle', 'extra']
  }, '/x', []).ok, false);
  const defaults = Provider.validateManifest({
    protocol: 2, id: 'defaults', executable: 'run', enabled: true,
    triggers: ['go'], timeoutMs: 'bad', killAfterMs: 'bad', maxRows: 'bad', maxLineBytes: 'bad',
    capabilities: 'bad'
  }, '/x/', []).value;
  assert.equal(defaults.title, 'defaults');
  assert.equal(defaults.queryPolicy, 'triggered');
  assert.deepEqual(defaults.capabilities, []);
  assert.deepEqual([defaults.timeoutMs, defaults.killAfterMs, defaults.maxRows, defaults.maxLineBytes],
    [900, 200, 8, 16384]);
  assert.equal(Provider.validateManifest({
    ...manifest, id: 'all', queryPolicy: 'unrestricted', triggers: []
  }, '/x', null).ok, false);
});

test('covers trigger and context absence branches', () => {
  const checked = Provider.validateManifest(manifest, '/x', []).value;
  assert.equal(Provider.triggerMatch(null, 'anything'), true);
  assert.equal(Provider.triggerMatch(checked, null), false);
  assert.equal(Provider.queryBody(null, ' x '), 'x');
  assert.equal(Provider.queryBody(checked, 'package:bat'), 'bat');
  assert.deepEqual(Provider.filterContext(checked, {}), {});
  assert.deepEqual(Provider.filterContext({ context: 'bad' }, { workspace: '3' }), {});
});

test('covers action defaults and every malformed argv or policy boundary', () => {
  const common = { id: 'x', title: 'X', executor: 'argv', argv: ['true'] };
  const defaults = Provider.validateAction(common).value;
  assert.equal(defaults.risk, 'safe');
  assert.equal(defaults.lifecycle, 'close');
  assert.equal(defaults.subtitle, '');
  assert.equal(Provider.validateAction(null).ok, false);
  assert.equal(Provider.validateAction({ ...common, id: '_bad' }).ok, false);
  assert.equal(Provider.validateAction({ ...common, title: 7 }).ok, false);
  assert.equal(Provider.validateAction({ ...common, title: 'bad\nline' }).ok, false);
  assert.equal(Provider.validateAction({ ...common, argv: 'bad' }).ok, false);
  assert.equal(Provider.validateAction({ ...common, argv: Array(65).fill('x') }).ok, false);
  assert.equal(Provider.validateAction({ ...common, argv: [7] }).ok, false);
  assert.equal(Provider.validateAction({ ...common, argv: ['x'.repeat(16385)] }).ok, false);
  assert.equal(Provider.validateAction({ ...common, risk: 'unknown' }).ok, false);
  assert.equal(Provider.validateAction({ ...common, lifecycle: 'forever' }).ok, false);
});

test('covers result defaults, cycles, namespace limits, and field bounds', () => {
  const minimal = {
    protocol: 2, id: 'row', title: 'Row',
    actions: [{ id: 'open', title: 'Open', executor: 'argv', argv: ['true'] }]
  };
  const checked = Provider.validateResult('example', minimal).value;
  assert.equal(checked.type, 'provider');
  assert.equal(checked.subtitle, '');
  assert.equal(checked.value.data, null);
  assert.equal(checked.matchScore, 0);
  assert.deepEqual(checked.aliases, []);
  assert.equal(Provider.validateResult('example', { ...minimal, subtitle: 'bad\nline' }).ok, false);
  assert.equal(Provider.validateResult('example', {
    ...minimal, actions: Array(17).fill(minimal.actions[0])
  }).ok, false);
  assert.equal(Provider.validateResult('x'.repeat(64), {
    ...minimal, id: 'y'.repeat(255)
  }).ok, false);
  const cyclic = {};
  cyclic.self = cyclic;
  assert.equal(Provider.validateResult('example', { ...minimal, value: cyclic }).ok, false);
  assert.equal(Provider.validateResult('example', { ...minimal, aliases: 'bad' }).ok, false);
  assert.equal(Provider.validateResult('example', {
    ...minimal, aliases: Array(33).fill('x')
  }).ok, false);
  assert.equal(Provider.validateResult('example', { ...minimal, aliases: ['bad\nalias'] }).ok, false);
  const decorated = Provider.validateResult('example', {
    ...minimal, icon: 'x'.repeat(100), aliases: ['row alias'],
    matchScore: Number.NaN, value: undefined
  }).value;
  assert.equal(decorated.icon.length, 64);
  assert.deepEqual(decorated.aliases, ['row alias']);
});

test('core policy overrides mislabeled provider privilege and destructiveness', () => {
  const mislabeledRm = Provider.validateAction({
    id: 'delete', title: 'Delete', executor: 'argv', argv: ['rm', '--', '/tmp/file'],
    risk: 'safe', lifecycle: 'close'
  });
  assert.equal(mislabeledRm.ok, true);
  assert.equal(mislabeledRm.value.risk, 'destructive');
  assert.equal(mislabeledRm.value.confirm, true);

  const sudo = Provider.validateAction({
    id: 'sudo', title: 'Sudo', executor: 'argv', argv: ['sudo', '--', 'true'],
    risk: 'safe', lifecycle: 'close'
  }).value;
  assert.equal(sudo.risk, 'privileged');
  assert.equal(sudo.lifecycle, 'terminal');

  const refresh = Provider.validateAction({
    id: 'refresh', title: 'Refresh', executor: 'argv',
    argv: ['omarchy', 'refresh', 'pacman'], risk: 'safe', lifecycle: 'close'
  }).value;
  assert.equal(refresh.risk, 'destructive');
  assert.equal(refresh.confirm, true);

  for (const program of ['bash', 'sh', 'python', 'node', 'env', 'setsid',
    'timeout', 'nice', 'nohup', 'stdbuf', 'chrt', 'ionice', 'busybox', 'xargs',
    'find', 'systemd-run', 'parallel', 'unshare', 'nsenter', 'script', 'bwrap',
    'firejail', 'flatpak-spawn'])
    assert.equal(Provider.validateAction({
      id: 'opaque', title: 'Opaque', executor: 'argv',
      argv: [program, '-c', 'true'], risk: 'safe', lifecycle: 'close'
    }).ok, false, program);

  const packageInfo = Provider.validateAction(result.actions[0]);
  assert.equal(packageInfo.ok, true);
  assert.equal(packageInfo.value.risk, 'safe');
  assert.equal(packageInfo.value.lifecycle, 'close');
});

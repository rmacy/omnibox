const test = require('node:test');
const assert = require('node:assert/strict');
const keyboard = require('./fixtures/current-keyboard.json');
const ranking = require('./fixtures/current-ranking.json');
const results = require('./fixtures/current-results.json');

test('keyboard migration fixture records every existing interaction', () => {
  assert.deepEqual(keyboard, [
    { key: 'Escape', condition: 'query-not-empty', intent: 'clear-query' },
    { key: 'Escape', condition: 'query-empty', intent: 'close' },
    { key: 'Down', condition: 'always', intent: 'select', delta: 1 },
    { key: 'Up', condition: 'always', intent: 'select', delta: -1 },
    { key: 'PageDown', condition: 'always', intent: 'select', delta: 6 },
    { key: 'PageUp', condition: 'always', intent: 'select', delta: -6 },
    { key: 'Enter', condition: 'always', intent: 'activate-primary' },
    { key: 'Alt+Enter', condition: 'selected-file', intent: 'reveal-file' }
  ]);
});

test('source migration fixture records all ten current primary behaviors', () => {
  const expected = {
    calc: 'calculation.copy',
    apps: 'app.open',
    windows: 'window.focus',
    files: 'file.open',
    clipboard: 'clipboard.paste',
    system: 'system.lock',
    web: 'web.open',
    ssh: 'ssh.connect',
    run: 'shell.run-terminal',
    providers: 'provider.run'
  };
  assert.equal(results.length, 10);
  for (const row of results) {
    assert.equal(row.actions[0].id, expected[row.source]);
    delete expected[row.source];
  }
  assert.deepEqual(expected, {});
});

test('ranking fixture records fixed buckets and required global correction', () => {
  assert.deepEqual(ranking.sourceOrder, [
    'calc', 'apps', 'windows', 'files', 'clipboard',
    'system', 'web', 'ssh', 'run', 'providers'
  ]);
  assert.equal(ranking.crossSourceScenario.currentBucketWinner, 'app:reboot-tool');
  assert.equal(ranking.crossSourceScenario.requiredGlobalWinner, 'command:reboot');
});

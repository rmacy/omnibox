const test = require('node:test');
const assert = require('node:assert/strict');
const Registry = require('../js/Registry.js');

test('builds a deterministic ordered registry without mutating input', () => {
  const definitions = [
    { id: 'zeta', label: 'Zeta', order: 2, collect: () => [] },
    { id: 'alpha', label: 'Alpha', order: 1, collect: () => [] },
    { id: 'beta', collect: () => [] }
  ];
  const before = definitions.map(x => ({ ...x }));
  const built = Registry.build(definitions);
  assert.equal(built.ok, true);
  assert.deepEqual(built.value.ordered.map(x => x.id), ['beta', 'alpha', 'zeta']);
  assert.equal(built.value.byId.alpha.label, 'Alpha');
  assert.deepEqual(definitions, before);
});

test('rejects malformed and duplicate source definitions', () => {
  assert.equal(Registry.build(null).ok, false);
  assert.match(Registry.build([null]).error, /object/);
  assert.match(Registry.build([{ id: 'bad id', collect() {} }]).error, /invalid id/);
  assert.match(Registry.build([{ id: 'x' }]).error, /collect/);
  assert.match(Registry.build([{ id: 'x', collect() {}, available: 'yes' }]).error, /availability/);
  assert.match(Registry.build([
    { id: 'x', collect() {} }, { id: 'x', collect() {} }
  ]).error, /Duplicate/);
});

test('collects available sources, stamps provenance, and preserves ordering', () => {
  const built = Registry.build([
    { id: 'second', order: 2, collect: () => [{ id: 'two' }] },
    { id: 'first', order: 1, collect: parsed => [{ id: parsed.text, source: 'explicit' }] },
    { id: 'disabled', order: 0, available: false, collect: () => [{ id: 'no' }] },
    { id: 'contextual', order: 3, available: context => context.enabled, collect: () => [] }
  ]).value;
  const collected = Registry.collect(built, { text: 'query' }, { enabled: true });
  assert.equal(collected.ok, true);
  assert.deepEqual(collected.value.results, [
    { id: 'query', source: 'explicit' },
    { id: 'two', source: 'second' }
  ]);
  assert.deepEqual(collected.value.diagnostics, []);
});

test('isolates collector and availability failures', () => {
  const built = Registry.build([
    { id: 'good', collect: () => [{ id: 'good' }] },
    { id: 'bad-return', collect: () => ({}) },
    { id: 'bad-collect', collect: () => { throw new Error('secret '.repeat(200)); } },
    { id: 'bad-available', available: () => { throw new Error('availability failed'); }, collect: () => [] },
    { id: 'junk-rows', collect: () => [null, 7, { id: 'kept' }] }
  ]).value;
  const collected = Registry.collect(built, {}, {});
  assert.deepEqual(collected.value.results.map(x => x.id), ['good', 'kept']);
  assert.equal(collected.value.diagnostics.length, 3);
  assert.ok(collected.value.diagnostics.every(x => x.error.length <= 512));
});

test('rejects invalid registry and validates IDs', () => {
  assert.equal(Registry.collect({}, {}, {}).ok, false);
  assert.equal(Registry.stableId('source:files'), true);
  assert.equal(Registry.stableId('_bad'), false);
});

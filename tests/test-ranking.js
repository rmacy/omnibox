const test = require('node:test');
const assert = require('node:assert/strict');
const Ranking = require('../js/Ranking.js');

test('exact cross-source matches beat weak earlier-source matches', () => {
  const rows = [
    { id: 'app:reboot-tool', source: 'apps', title: 'Reboot Tool', matchScore: 60 },
    { id: 'command:reboot', source: 'system', title: 'Reboot', matchScore: 1 }
  ];
  assert.equal(Ranking.rank('reboot', rows, {})[0].id, 'command:reboot');
});

test('aliases, prefixes, word boundaries, and intent contribute separately', () => {
  const candidate = { id: 'project:omnibox', source: 'projects', title: 'Omnibox Project', aliases: ['omni'] };
  const alias = Ranking.explain('omni', candidate, { intentSource: 'projects' });
  assert.equal(alias.alias, -90);
  assert.equal(alias.prefix, -35);
  assert.equal(alias.word, -15);
  assert.equal(alias.intent, -25);
  assert.equal(Object.hasOwn(alias, 'query'), false);
});

test('pins, frequency, and recency are bounded', () => {
  const now = 1_800_000_000_000;
  const candidate = { id: 'file:a', source: 'files', title: 'a', matchScore: 0 };
  const parts = Ranking.explain('a', candidate, {
    pins: { 'file:a': true },
    usage: { 'file:a': { count: 1e100, lastUsed: now } },
    now
  });
  assert.equal(parts.pin, -100);
  assert.equal(parts.frequency, -18);
  assert.equal(parts.recency, -12);
  const old = Ranking.explain('a', candidate, {
    usage: { 'file:a': { count: 1, lastUsed: now - 20 * 86400000 } }, now
  });
  assert.equal(old.recency, 0);
});

test('source priors are clamped and only affect close scores', () => {
  const rows = [
    { id: 'a', source: 'apps', title: 'thing', matchScore: 20 },
    { id: 'b', source: 'files', title: 'thing', matchScore: 30 }
  ];
  const ranked = Ranking.rank('thing', rows, { sourcePriors: { apps: 999, files: -999 } });
  assert.equal(ranked[0].id, 'a');
  assert.equal(ranked[0].scoreParts.prior, 5);
  assert.equal(ranked[1].scoreParts.prior, -5);
});

test('invalid numeric values cannot produce NaN', () => {
  const parts = Ranking.explain('x', {
    id: 'x', source: 'apps', title: 'x', matchScore: Number.NaN
  }, {
    now: Number.NaN,
    usage: { x: { count: Number.POSITIVE_INFINITY, lastUsed: -1 } },
    sourcePriors: { apps: Number.NaN }
  });
  assert.ok(Number.isFinite(parts.total));
  assert.equal(parts.match, 1000);
  assert.equal(parts.frequency, 0);
  assert.equal(parts.prior, 0);
});

test('ranking is stable, sums explanations, and does not mutate input', () => {
  const rows = [
    { id: 'b', source: 'files', title: 'same', matchScore: 0, nested: { keep: true } },
    { id: 'a', source: 'files', title: 'same', matchScore: 0 }
  ];
  const before = structuredClone(rows);
  const ranked = Ranking.rank('other', rows, {});
  assert.deepEqual(ranked.map(x => x.id), ['a', 'b']);
  for (const row of ranked) {
    const components = Object.entries(row.scoreParts)
      .filter(([key]) => key !== 'total')
      .reduce((sum, [, value]) => sum + value, 0);
    assert.equal(row.score, components);
  }
  assert.deepEqual(rows, before);
});

test('handles arrays, strings, and missing candidates', () => {
  assert.deepEqual(Ranking.rank('x', null, {}), []);
  assert.deepEqual(Ranking.rank('x', [null, 4], {}), []);
  const stringAlias = Ranking.explain('alias', { id: 'x', source: 'x', title: 'title', aliases: 'alias other' }, {});
  assert.equal(stringAlias.alias, -90);
  assert.equal(Ranking.normalize(null), '');
});

test('handles repeated substrings, array pins, missing signals, and stable duplicates', () => {
  const boundary = Ranking.explain('query', {
    id: 'x', source: 'files', title: 'xquery query', matchScore: 0
  }, {});
  assert.equal(boundary.word, -15);
  const absent = Ranking.explain('missing', {
    id: 'x', source: 'files', title: 'xquery', matchScore: 0
  }, {});
  assert.equal(absent.word, 0);
  assert.equal(Ranking.explain('', null, {}).total, 1000);
  assert.equal(Ranking.explain('x', {
    id: 'x', source: 'files', title: 'x', matchScore: 0
  }, { pins: ['x'] }).pin, -100);
  const duplicates = Ranking.rank('x', [
    { id: 'same', source: 'files', title: 'x', matchScore: 0, ordinal: 1 },
    { id: 'same', source: 'files', title: 'x', matchScore: 0, ordinal: 2 }
  ], {});
  assert.deepEqual(duplicates.map(x => x.ordinal), [1, 2]);
});

test('uses labels, fallback scores, future timestamps, and negative usage safely', () => {
  const now = 1_800_000_000_000;
  const parts = Ranking.explain('label', {
    id: 'label', source: 'misc', label: 'Label', score: 4
  }, {
    usage: { label: { count: -5, lastUsed: now + 1000 } },
    now
  });
  assert.equal(parts.match, 4);
  assert.equal(parts.frequency, 0);
  assert.equal(parts.recency, 0);
});

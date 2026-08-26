const test = require('node:test');
const assert = require('node:assert/strict');
const Query = require('../js/Query.js');

test('parses normal, shell, agent, and calculator modes', () => {
  assert.deepEqual(Query.parse('  ghost  '), {
    raw: '  ghost  ', text: 'ghost', body: 'ghost', mode: 'Search', forced: false,
    aliasResultId: '', aliasActionId: ''
  });
  assert.equal(Query.parse(' >  uname -a ').mode, 'Shell');
  assert.equal(Query.parse(' >  uname -a ').body, 'uname -a');
  assert.equal(Query.parse(' ?  fix $(touch /tmp/no); `id` ').mode, 'Agent');
  assert.equal(Query.parse(' ?  fix $(touch /tmp/no); `id` ').body,
    'fix $(touch /tmp/no); `id`');
  assert.equal(Query.parse('?').forced, true);
  assert.equal(Query.parse('= 2 + 2').mode, 'Calculator');
  assert.equal(Query.parse('= 2 + 2').body, '2 + 2');
  assert.equal(Query.parse('= 2 + 2').forced, true);
});

test('normalizes empty and non-string values deterministically', () => {
  assert.equal(Query.parse(null).text, '');
  assert.equal(Query.parse(undefined).raw, '');
  assert.equal(Query.parse(42).text, '42');
  assert.equal(Query.normalize('  HéLLo\nWORLD '), 'héllo\nworld');
});

test('resolves exact safe aliases only', () => {
  const aliases = {
    Omni: { resultId: 'project:omnibox', actionId: 'project.resume' },
    term: 'app:ghostty',
    unsafe: { resultId: '$(touch:/tmp/no)', actionId: '' },
    badAction: { resultId: 'app:ghostty', actionId: '$(bad)' },
    malformed: 42
  };
  const omni = Query.parse('  OMNI ', aliases);
  assert.equal(omni.aliasResultId, 'project:omnibox');
  assert.equal(omni.aliasActionId, 'project.resume');
  assert.equal(Query.parse('term', aliases).aliasResultId, 'app:ghostty');
  assert.equal(Query.parse('om', aliases).aliasResultId, '');
  assert.equal(Query.parse('unsafe', aliases).aliasResultId, '');
  assert.equal(Query.parse('badAction', aliases).aliasResultId, '');
  assert.equal(Query.parse('malformed', aliases).aliasResultId, '');
  assert.equal(Query.parse('omni', null).aliasResultId, '');
});

test('prefix modes never resolve aliases', () => {
  const aliases = { '>ls': 'app:wrong', '?explain': 'app:wrong', '=2': 'app:wrong' };
  assert.equal(Query.parse('>ls', aliases).aliasResultId, '');
  assert.equal(Query.parse('?explain', aliases).aliasResultId, '');
  assert.equal(Query.parse('=2', aliases).aliasResultId, '');
});

test('validates stable identifiers', () => {
  assert.equal(Query.stableId('app:org.example/Foo-1'), true);
  assert.equal(Query.stableId(''), false);
  assert.equal(Query.stableId(' space'), false);
  assert.equal(Query.stableId('x'.repeat(257)), false);
  assert.equal(Query.stableId(7), false);
});

test('ignores inherited aliases and missing object identifiers', () => {
  const aliases = Object.create({ inherited: 'app:inherited' });
  aliases.own = { resultId: 'app:own' };
  aliases.missing = { actionId: 'app.open' };
  assert.equal(Query.parse('inherited', aliases).aliasResultId, '');
  assert.equal(Query.parse('own', aliases).aliasResultId, 'app:own');
  assert.equal(Query.parse('missing', aliases).aliasResultId, '');
  assert.equal(Query.normalize(undefined), '');
});

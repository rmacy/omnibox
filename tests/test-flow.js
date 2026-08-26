const test = require('node:test');
const assert = require('node:assert/strict');
const Flow = require('../js/Flow.js');

function value(result) {
  assert.equal(result.ok, true, result.error);
  return result.value;
}

test('creates Search state and reports current frame', () => {
  const state = value(Flow.create({ openedFrom: 'keyboard' }));
  assert.equal(state.frames.length, 1);
  assert.equal(value(Flow.current(state)).mode, 'Search');
  assert.equal(value(Flow.current(state)).data.openedFrom, 'keyboard');
  assert.equal(state.closed, false);
});

test('supports legal interactive transitions and bounded depth', () => {
  let state = value(Flow.create());
  state = value(Flow.push(state, 'Actions', 'File actions', { resultId: 'file:a' }));
  state = value(Flow.push(state, 'Arguments', 'Workspace', {}));
  state = value(Flow.push(state, 'Confirm', 'Confirm move', {}));
  assert.equal(state.frames.length, 4);
  assert.equal(value(Flow.current(state)).mode, 'Confirm');
  assert.match(Flow.push(state, 'Arguments', 'Too deep', {}).error, /depth/);
});

test('rejects illegal modes and transitions', () => {
  const search = value(Flow.create());
  assert.match(Flow.push(search, 'Result', 'No', {}).error, /Invalid interactive mode/);
  assert.match(Flow.push(search, 'Search', 'No', {}).error, /Illegal transition/);
  const actions = value(Flow.push(search, 'Actions', 'Actions', {}));
  const confirm = value(Flow.push(actions, 'Confirm', 'Confirm', {}));
  assert.match(Flow.push(confirm, 'Actions', 'No', {}).error, /Illegal transition/);
  assert.equal(Flow.current({}).ok, false);
});

test('preserves query and selection while navigating back', () => {
  let state = value(Flow.create());
  state = value(Flow.setQuery(state, 'notes'));
  state = value(Flow.setSelection(state, 'file:notes'));
  state = value(Flow.push(state, 'Actions', 'Actions', {}));
  state = value(Flow.setQuery(state, 'copy'));
  state = value(Flow.pop(state));
  const current = value(Flow.current(state));
  assert.equal(current.query, 'notes');
  assert.equal(current.selectedId, 'file:notes');
});

test('popping root requests close without mutating input', () => {
  const state = value(Flow.create());
  const before = structuredClone(state);
  const closed = value(Flow.pop(state));
  assert.equal(closed.closed, true);
  assert.deepEqual(state, before);
});

test('runs, succeeds, and ignores stale completion tokens', () => {
  let state = value(Flow.create());
  state = value(Flow.setQuery(state, 'ghost'));
  const started = value(Flow.begin(state, 'Open Ghostty', { actionId: 'app.open' }));
  assert.equal(started.token, '1');
  assert.equal(value(Flow.current(started.state)).mode, 'Running');
  assert.equal(Flow.succeed(started.state, 'stale', 'No').ok, false);
  const finished = value(Flow.succeed(started.state, started.token, 'Opened', { exitStatus: 0 }));
  const result = value(Flow.current(finished));
  assert.equal(result.mode, 'Result');
  assert.equal(result.data.ok, true);
  assert.equal(result.data.message, 'Opened');
  assert.equal(result.data.result.exitStatus, 0);
  assert.equal(finished.activeToken, '');
});

test('reports failures and cancellation', () => {
  const first = value(Flow.begin(value(Flow.create()), 'Failing action', {}));
  const failed = value(Flow.fail(first.state, first.token, 'exit 7', { exitStatus: 7 }));
  assert.equal(value(Flow.current(failed)).data.ok, false);
  assert.equal(value(Flow.current(failed)).data.canceled, false);

  const second = value(Flow.begin(value(Flow.create()), 'Cancelable', {}));
  assert.equal(Flow.cancel(second.state, 'old').ok, false);
  const canceled = value(Flow.cancel(second.state, second.token));
  assert.equal(value(Flow.current(canceled)).data.canceled, true);
  assert.equal(value(Flow.current(canceled)).title, 'Canceled');
});

test('begin at maximum depth replaces Confirm and retains parent frames', () => {
  let state = value(Flow.create());
  state = value(Flow.push(state, 'Actions', 'Actions', {}));
  state = value(Flow.push(state, 'Arguments', 'Args', {}));
  state = value(Flow.push(state, 'Confirm', 'Confirm', {}));
  const started = value(Flow.begin(state, 'Run', {}));
  assert.equal(started.state.frames.length, 4);
  assert.deepEqual(started.state.frames.map(x => x.mode), ['Search', 'Actions', 'Arguments', 'Running']);
});

test('editing and navigation reject Running state', () => {
  const started = value(Flow.begin(value(Flow.create()), 'Run', {}));
  assert.equal(Flow.setQuery(started.state, 'no').ok, false);
  assert.equal(Flow.setSelection(started.state, 'no').ok, false);
  assert.equal(Flow.pop(started.state).ok, false);
  assert.equal(Flow.begin(started.state, 'again', {}).ok, false);
  assert.equal(Flow.fail(started.state, '', 'bad').ok, false);
});

test('cancel outside Running behaves like back and reset clears state', () => {
  let state = value(Flow.create());
  state = value(Flow.push(state, 'Actions', 'Actions', {}));
  state = value(Flow.cancel(state));
  assert.equal(value(Flow.current(state)).mode, 'Search');
  state = value(Flow.setQuery(state, 'dirty'));
  const reset = value(Flow.reset({ clean: true }));
  assert.equal(value(Flow.current(reset)).query, '');
  assert.equal(value(Flow.current(reset)).data.clean, true);
});

test('all state transforms are immutable', () => {
  const initial = value(Flow.create({ nested: 'value' }));
  const before = structuredClone(initial);
  value(Flow.setQuery(initial, 'changed'));
  value(Flow.setSelection(initial, 'id'));
  value(Flow.push(initial, 'Actions', 'Actions', {}));
  value(Flow.begin(initial, 'Run', {}));
  assert.deepEqual(initial, before);
});

test('covers every interactive source mode and defensive state branch', () => {
  assert.equal(Flow.create().ok, true);
  assert.equal(Flow.current({ frames: [], runSerial: 0 }).ok, false);
  assert.equal(Flow.push(null, 'Actions', '', {}).ok, false);
  assert.equal(Flow.pop(null).ok, false);
  assert.equal(Flow.setQuery(null, 'x').ok, false);
  assert.equal(Flow.begin(null, 'x', {}).ok, false);
  assert.equal(Flow.cancel(null, 'x').ok, false);

  const search = value(Flow.create());
  const argumentsDirect = value(Flow.push(search, 'Arguments', 'Args', []));
  const nestedArguments = value(Flow.push(argumentsDirect, 'Arguments', 'More args', null));
  const startedFromArguments = value(Flow.begin(nestedArguments, 'Run args', null));
  assert.equal(value(Flow.current(startedFromArguments.state)).mode, 'Running');

  const actions = value(Flow.push(search, 'Actions', 'Actions', {}));
  const startedFromActions = value(Flow.begin(actions, 'Run action', {}));
  assert.equal(value(Flow.current(startedFromActions.state)).mode, 'Running');
  assert.equal(Flow.succeed(search, '1', 'no').ok, false);
  assert.equal(Flow.fail(null, '1', 'no').ok, false);
});

test('copies plain data defensively while retaining primitive and array values', () => {
  const inherited = Object.create({ ignored: true });
  inherited.kept = 'yes';
  let state = value(Flow.create(inherited));
  assert.deepEqual(value(Flow.current(state)).data, { kept: 'yes' });
  state = value(Flow.push(state, 'Actions', '', ['a']));
  assert.deepEqual(value(Flow.current(state)).data, ['a']);
  state = value(Flow.setQuery(state, 0));
  state = value(Flow.setSelection(state, null));
  assert.equal(value(Flow.current(state)).query, '');
  assert.equal(value(Flow.current(state)).selectedId, '');
});

test('result and cancellation frames can be popped back to prior state', () => {
  let state = value(Flow.create());
  state = value(Flow.push(state, 'Actions', 'Actions', {}));
  const started = value(Flow.begin(state, 'Run', {}));
  state = value(Flow.succeed(started.state, started.token, '', null));
  state = value(Flow.pop(state));
  assert.equal(value(Flow.current(state)).mode, 'Actions');

  const second = value(Flow.begin(state, 'Run again', {}));
  state = value(Flow.cancel(second.state, second.token));
  state = value(Flow.pop(state));
  assert.equal(value(Flow.current(state)).mode, 'Actions');
});

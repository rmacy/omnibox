const test = require('node:test');
const assert = require('node:assert/strict');
const Native = require('../js/Native.js');

const catalog = {
  ok: true,
  commands: [
    {
      route: 'omarchy theme set', binary: 'omarchy-theme-set', group: 'theme', name: 'set',
      summary: 'Apply an Omarchy theme', args: '<theme-name>', examples: ['omarchy theme set "Tokyo Night"'],
      aliases: [], requires_sudo: false, hidden: false
    },
    {
      route: 'omarchy system shutdown', binary: 'omarchy-system-shutdown', group: 'system', name: 'shutdown',
      summary: 'Shutdown the system', args: '', examples: [], aliases: [], requires_sudo: false, hidden: false
    },
    {
      route: 'omarchy update', binary: 'omarchy-update', group: 'update', name: '',
      summary: 'Update packages', args: '[-y]', examples: [], aliases: [], requires_sudo: true, hidden: false
    },
    {
      route: 'omarchy hidden thing', binary: 'omarchy-hidden-thing', group: 'hidden', name: 'thing',
      summary: 'Secret exact token', args: '', examples: [], aliases: [], requires_sudo: false, hidden: true
    }
  ]
};

test('parses and copies the documented command catalog', () => {
  const parsed = Native.parseCatalog(JSON.stringify(catalog));
  assert.equal(parsed.ok, true);
  assert.equal(parsed.value.length, 4);
  assert.deepEqual(parsed.value[0].examples, ['omarchy theme set "Tokyo Night"']);
  parsed.value[0].examples[0] = 'changed';
  assert.equal(catalog.commands[0].examples[0], 'omarchy theme set "Tokyo Night"');
});

test('rejects catalog absence, invalid JSON, drift, foreign routes, and bounds', () => {
  assert.match(Native.parseCatalog('').error, /Invalid/);
  assert.match(Native.parseCatalog('{}').error, /requires/);
  assert.equal(Native.parseCatalog(JSON.stringify({ ok: true, commands: [null] })).ok, false);
  assert.equal(Native.parseCatalog(JSON.stringify({ ok: true, commands: [{ ...catalog.commands[0], route: 7 }] })).ok, false);
  assert.equal(Native.parseCatalog(JSON.stringify({ ok: true, commands: [{ ...catalog.commands[0], binary: '' }] })).ok, false);
  assert.equal(Native.parseCatalog(JSON.stringify({ ok: true, commands: [{ ...catalog.commands[0], route: 'other command' }] })).ok, false);
  assert.equal(Native.parseCatalog(JSON.stringify({ ok: true, commands: Array(2001).fill(catalog.commands[0]) })).ok, false);
  assert.equal(Native.parseCatalog(JSON.stringify({ ok: true, commands: [{ ...catalog.commands[0], aliases: 'bad' }] })).ok, false);
  assert.equal(Native.parseCatalog(JSON.stringify({ ok: true, commands: [{ ...catalog.commands[0], summary: 'x'.repeat(16385) }] })).ok, false);
});

test('detects required arguments outside optional groups', () => {
  assert.equal(Native.hasRequiredArgs('<path> [--force]'), true);
  assert.equal(Native.hasRequiredArgs('[<optional>]'), false);
  assert.equal(Native.hasRequiredArgs('[-y]'), false);
  assert.equal(Native.hasRequiredArgs(''), false);
});

test('parses words without shell expansion', () => {
  assert.deepEqual(Native.parseWords(`one 'two three' "four five" six\\ seven`).value,
    ['one', 'two three', 'four five', 'six seven']);
  assert.deepEqual(Native.parseWords('$(touch /tmp/no) `id`;').value,
    ['$(touch', '/tmp/no)', '`id`;']);
  assert.deepEqual(Native.parseWords(`'' ""`).value, ['', '']);
  assert.match(Native.parseWords("'unterminated").error, /Unterminated/);
  assert.match(Native.parseWords('trailing\\').error, /escape/);
  assert.deepEqual(Native.routeArgv('omarchy theme list'), ['omarchy', 'theme', 'list']);
  assert.deepEqual(Native.routeArgv('foreign command'), []);
});

test('classifies privilege separately from destructiveness', () => {
  const shutdown = Native.classify(catalog.commands[1]);
  assert.equal(shutdown.risk, 'destructive');
  assert.equal(shutdown.confirm, true);
  assert.equal(shutdown.privileged, false);
  assert.equal(shutdown.lifecycle, 'close');
  const update = Native.classify(catalog.commands[2]);
  assert.equal(update.risk, 'destructive');
  assert.equal(update.lifecycle, 'terminal');
  assert.equal(update.confirm, true);
  assert.equal(update.privileged, true);
  const refreshPacman = Native.classify({
    route: 'omarchy refresh pacman', group: 'refresh', requires_sudo: true
  });
  assert.equal(refreshPacman.risk, 'destructive');
  assert.equal(refreshPacman.confirm, true);
  const remote = Native.classify({ route: 'omarchy tailscale send', group: 'tailscale' });
  assert.equal(remote.risk, 'remote');
  assert.equal(remote.confirm, true);
  assert.equal(Native.classify({ route: 'omarchy setup foo', group: 'setup' }).interactive, true);
  assert.equal(Native.classify(catalog.commands[0]).confirm, true);
  assert.equal(Native.classify(catalog.commands[0]).lifecycle, 'terminal');
  assert.equal(Native.classify({ route: 'omarchy menu select', group: 'menu' }).interactive, true);
  assert.equal(Native.classify({ route: 'omarchy capture text', group: 'capture' }).lifecycle, 'close');
  assert.equal(Native.classify({ route: 'omarchy finalize setup', group: 'finalize' }).lifecycle, 'terminal');
});

test('reclassifies destructive typed subcommands after argument resolution', () => {
  const snapshot = { route: 'omarchy snapshot', group: 'snapshot', requires_sudo: true };
  const create = Native.classifyResolved(snapshot, ['omarchy', 'snapshot', 'create']);
  assert.equal(create.risk, 'privileged');
  assert.equal(create.confirm, false);
  const restore = Native.classifyResolved(snapshot, ['omarchy', 'snapshot', 'restore']);
  assert.equal(restore.risk, 'destructive');
  assert.equal(restore.confirm, true);
  assert.equal(restore.lifecycle, 'terminal');
  const remove = Native.classifyResolved(
    { route: 'omarchy windows vm', group: 'windows', requires_sudo: false },
    ['omarchy', 'windows', 'vm', 'remove', 'work']
  );
  assert.equal(remove.risk, 'destructive');
  assert.equal(remove.confirm, true);
});

test('searches every documented field and excludes hidden commands', () => {
  const commands = Native.parseCatalog(JSON.stringify(catalog)).value;
  const score = (query, text) => {
    const index = text.toLowerCase().indexOf(query.toLowerCase());
    return index < 0 ? null : index;
  };
  assert.equal(Native.search(commands, 'apply', score, 8)[0].route, 'omarchy theme set');
  assert.equal(Native.search(commands, 'Tokyo', score, 8)[0].route, 'omarchy theme set');
  assert.equal(Native.search(commands, 'theme-name', score, 8)[0].route, 'omarchy theme set');
  assert.deepEqual(Native.search(commands, 'Secret exact token', score, 8), []);
  assert.deepEqual(Native.search(commands, 'x', score, 8), []);
  assert.deepEqual(Native.search(null, 'theme', score, 8), []);
  assert.equal(Native.search(commands, 'shutdown', null, 100)[0].policy.confirm, true);
});

test('builds reminder creation and listing intents', () => {
  const create = Native.intentRows('remind me in 20 minutes Check oven', {})[0];
  assert.deepEqual(create.argv, ['omarchy', 'reminder', '20', 'Check oven']);
  assert.match(create.title, /Check oven/);
  assert.deepEqual(Native.intentRows('remind 5', {})[0].argv, ['omarchy', 'reminder', '5']);
  assert.deepEqual(Native.intentRows('show reminders', {})[0].argv,
    ['omarchy', 'reminder', 'show', '--json']);
  assert.equal(Native.intentRows('show reminders', {})[0].outputFormat, 'reminders');
  assert.deepEqual(Native.intentRows('remind 0 no', {}), []);
});

test('selects live themes with spaces and literal argv', () => {
  const rows = Native.intentRows('theme tokyo', {
    themes: ['Tokyo Night', 'Catppuccin'],
    scoreFn: (query, text) => text.toLowerCase().startsWith(query.toLowerCase()) ? 1 : null
  });
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].argv, ['omarchy', 'theme', 'set', 'Tokyo Night']);
  assert.equal(rows[0].confirm, true);
});

test('builds screenshot, toggle, audio, brightness, and text-size intents', () => {
  assert.deepEqual(Native.intentRows('screenshot region copy', {})[0].argv,
    ['omarchy', 'capture', 'screenshot', 'region', 'copy']);
  const screenshot = Native.intentRows('screenshot', {})[0];
  assert.deepEqual(screenshot.argv, ['omarchy', 'capture', 'screenshot']);
  assert.deepEqual(screenshot.argumentOrder, ['mode', 'destination']);
  assert.deepEqual(screenshot.argumentFields.map(field => field.values.length), [4, 3]);
  assert.equal(screenshot.argumentValueMap.destination.edit, 'slurp');
  const omasnap = Native.intentRows('screenshot region copy', {
    states: { omasnap: 'available' }
  })[0];
  assert.deepEqual(omasnap.argv, ['omasnap', 'region', '--copy']);
  const omasnapPicker = Native.intentRows('screenshot', {
    states: { omasnap: 'available' }
  })[0];
  assert.equal(omasnapPicker.argumentValueMap.destination.edit, '');
  assert.equal(omasnapPicker.argumentValueMap.destination.copy, '--copy');
  const routed = Native.intentRows('screenshot region copy', {
    screenshotHelper: '/plugin/bin/capture-screenshot',
    states: { omasnap: 'unavailable' }
  })[0];
  assert.deepEqual(routed.argv, ['/plugin/bin/capture-screenshot', 'region', '--copy']);
  const routedPicker = Native.intentRows('screenshot', {
    screenshotHelper: '/plugin/bin/capture-screenshot'
  })[0];
  assert.deepEqual(routedPicker.argv, ['/plugin/bin/capture-screenshot']);
  assert.equal(routedPicker.argumentValueMap.destination.save, '--save');
  assert.deepEqual(Native.intentRows('stay awake', { states: { idle: 'allowed' } })[0].argv,
    ['omarchy', 'toggle', 'idle', 'stay-awake']);
  assert.match(Native.intentRows('stay awake', { states: { idle: 'allowed' } })[0].subtitle, /allowed/);
  assert.deepEqual(Native.intentRows('allow idle', {})[0].argv, ['omarchy', 'toggle', 'idle', 'allow-idle']);
  assert.deepEqual(Native.intentRows('night light', {})[0].argv, ['omarchy', 'toggle', 'nightlight']);
  assert.deepEqual(Native.intentRows('dnd', {})[0].argv, ['omarchy', 'toggle', 'notification', 'silencing']);
  assert.deepEqual(Native.intentRows('bluetooth off', {})[0].argv, ['omarchy', 'bluetooth', 'power', 'off']);
  assert.deepEqual(Native.intentRows('bar toggle', {})[0].argv, ['omarchy', 'toggle', 'bar', 'toggle']);
  assert.deepEqual(Native.intentRows('volume mute', {})[0].argv, ['omarchy', 'audio', 'output', 'volume', 'mute-toggle']);
  assert.deepEqual(Native.intentRows('vol +10', {})[0].argv, ['omarchy', 'audio', 'output', 'volume', '+10']);
  assert.deepEqual(Native.intentRows('brightness 50', {})[0].argv, ['omarchy', 'brightness', 'display', '50%']);
  assert.deepEqual(Native.intentRows('brightness off', {})[0].argv, ['omarchy', 'brightness', 'display', 'off']);
  assert.deepEqual(Native.intentRows('text size 14', {})[0].argv, ['omarchy', 'display', 'text', 'size', '14']);
  assert.deepEqual(Native.intentRows('font size reset', {})[0].argv, ['omarchy', 'display', 'text', 'size', 'reset']);
  assert.deepEqual(Native.intentRows('background next', {})[0].argv,
    ['omarchy', 'theme', 'bg', 'next']);
  assert.deepEqual(Native.intentRows('background switcher', {})[0].argv,
    ['omarchy', 'theme', 'bg-switcher']);
  const background = Native.intentRows('set background', {})[0];
  assert.deepEqual(background.argv, ['omarchy', 'theme', 'bg', 'set']);
  assert.equal(background.argumentFields[0].type, 'file');
  assert.deepEqual(Native.intentRows('text size 99', {}), []);
});

test('preserves metacharacters as literal reminder and theme arguments', () => {
  assert.equal(Native.intentRows('text size 14', {})[0].confirm, true);
  const reminder = Native.intentRows('remind 10 $(touch /tmp/no);', {})[0];
  assert.equal(reminder.argv[3], '$(touch /tmp/no);');
  const theme = Native.intentRows('theme $(id)', {
    themes: ['$(id)'], scoreFn: () => 0
  })[0];
  assert.equal(theme.argv[3], '$(id)');
});

test('covers UTF-8 bounds, stable search ties, and every screenshot output branch', () => {
  assert.equal(Native.bytes('abc'), 3);
  assert.equal(Native.bytes('é'), 2);
  assert.equal(Native.bytes('漢'), 3);
  assert.equal(Native.bytes('😀'), 4);

  const tied = Native.search([
    { route: 'omarchy zed', summary: 'same', hidden: false },
    { route: 'omarchy alpha', summary: 'same', hidden: false },
    { route: 'omarchy later', summary: 'same', hidden: false }
  ], 'same', (_query, text) => text.includes('later') ? 2 : 1, 2);
  assert.deepEqual(tied.map(row => row.route), ['omarchy alpha', 'omarchy zed']);

  assert.deepEqual(Native.intentRows('screenshot fullscreen save', {
    states: { omasnap: 'available' }
  })[0].argv, ['omasnap', 'fullscreen', '--save']);
  assert.deepEqual(Native.intentRows('screenshot fullscreen edit', {
    states: { omasnap: 'available' }
  })[0].argv, ['omasnap', 'fullscreen']);
  assert.deepEqual(Native.intentRows('screenshot region edit', {})[0].argv,
    ['omarchy', 'capture', 'screenshot', 'region', 'slurp']);
});

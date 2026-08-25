var test = require('node:test');
var assert = require('node:assert/strict');

var Fuzzy = require('../js/Fuzzy.js');

test('score exposes every scoring tier in strict rank order', function () {
    var exact = Fuzzy.score('fb', 'fb');
    var prefix = Fuzzy.score('fb', 'fball');
    var boundary = Fuzzy.score('fb', 'foo bar');
    var substring = Fuzzy.score('fb', 'xfb');
    var subsequence = Fuzzy.score('fb', 'fxb');

    assert.equal(exact, 0);
    assert.equal(prefix, 10.5);
    assert.equal(boundary, 29.5);
    assert.equal(substring, 40.5);
    assert.equal(subsequence, 72);
    assert.ok(exact < prefix && prefix < boundary && boundary < substring && substring < subsequence);
});

test('score applies the long exact and prefix bonus without going below zero', function () {
    assert.equal(Fuzzy.score('fire', 'fire'), 0);
    assert.ok(Math.abs(Fuzzy.score('fire', 'firefox') - 5.7) < 0.0000001);
    assert.ok(Math.abs(Fuzzy.score('fir', 'firefox') - 10.7) < 0.0000001);
    assert.equal(Fuzzy.score('FIREFOX', 'firefox'), 0);
    assert.equal(Fuzzy.score('firefox', 'FIREFOX'), 0);
});

test('score keeps the best tier when several tiers are available', function () {
    assert.equal(Fuzzy.score('fb', 'fb bar'), 10.6);
    assert.equal(Fuzzy.score('fb', 'foo-bar-fb'), 29.5);
    assert.equal(Fuzzy.score('fb', 'zfb'), 40.5);
    assert.ok(Fuzzy.score('om', 'Omarchy') < Fuzzy.score('om', 'Documents'));
});

test('score recognizes every documented word separator', function () {
    var texts = ['foo bar', 'foo_bar', 'foo-bar', 'foo.bar', 'foo/bar'];
    var i;

    for (i = 0; i < texts.length; i++) {
        assert.equal(Fuzzy.score('fb', texts[i]), 29.5, texts[i]);
    }
});

test('score recognizes lowercase-to-uppercase camel boundaries from original case', function () {
    assert.equal(Fuzzy.score('fb', 'fooBar'), 28);
    assert.equal(Fuzzy.score('om', 'otherMenu'), 31);
    assert.equal(Fuzzy.score('FB', 'fooBar'), 28);
});

test('score splits query terms on spaces, tabs, newlines, and carriage returns', function () {
    assert.equal(Fuzzy.score('web\tbrow\nser\r', 'Web Browser'),
        Fuzzy.score('web', 'Web Browser') +
        Fuzzy.score('brow', 'Web Browser') +
        Fuzzy.score('ser', 'Web Browser'));
    assert.equal(Fuzzy.score(' \t\n\r ', 'anything'), 0);
});

test('score requires every term and sums successful term scores', function () {
    var web = Fuzzy.score('web', 'Web Browser');
    var brow = Fuzzy.score('brow', 'Web Browser');

    assert.equal(Fuzzy.score('web brow', 'Web Browser'), web + brow);
    assert.equal(Fuzzy.score('web zzz', 'Web Browser'), null);
    assert.equal(Fuzzy.score('zzz web', 'Web Browser'), null);
});

test('score accepts distant subsequences but rejects absent and out-of-order terms', function () {
    assert.equal(Fuzzy.score('abc', 'a111b111c'), 82);
    assert.equal(Fuzzy.score('xyz', 'abc'), null);
    assert.equal(Fuzzy.score('ba', 'abc'), null);
});

test('score coerces non-string query and text inputs to empty strings', function () {
    assert.equal(Fuzzy.score(null, 'abc'), 0);
    assert.equal(Fuzzy.score(42, 'abc'), 0);
    assert.equal(Fuzzy.score('a', null), null);
    assert.equal(Fuzzy.score('a', { value: 'abc' }), null);
});

test('score handles empty query and text combinations', function () {
    assert.equal(Fuzzy.score('', 'anything'), 0);
    assert.equal(Fuzzy.score('', ''), 0);
    assert.equal(Fuzzy.score('a', ''), null);
});

test('normalize lowercases, trims, and collapses every supported whitespace type', function () {
    assert.equal(Fuzzy.normalize('  Hello\t\tWORLD\nNext\rLine  '), 'hello world next line');
    assert.equal(Fuzzy.normalize('Already-Normal'), 'already-normal');
    assert.equal(Fuzzy.normalize(''), '');
    assert.equal(Fuzzy.normalize(' \t\n\r '), '');
});

test('normalize returns empty text for non-string values', function () {
    assert.equal(Fuzzy.normalize(null), '');
    assert.equal(Fuzzy.normalize(17), '');
    assert.equal(Fuzzy.normalize({ toString: function () { return 'unused'; } }), '');
});

test('prefixMatch finds case-insensitive prefixes across words and terms', function () {
    assert.equal(Fuzzy.prefixMatch('fi fo', 'Firefox Focus'), true);
    assert.equal(Fuzzy.prefixMatch('FO fi', 'Firefox Focus'), true);
    assert.equal(Fuzzy.prefixMatch('fire fox', 'Firefox Foxglove'), true);
    assert.equal(Fuzzy.prefixMatch('fi fi', 'Firefox'), true);
});

test('prefixMatch rejects a missing prefix, empty text, and non-prefix substrings', function () {
    assert.equal(Fuzzy.prefixMatch('fi zz', 'Firefox Focus'), false);
    assert.equal(Fuzzy.prefixMatch('ire', 'Firefox'), false);
    assert.equal(Fuzzy.prefixMatch('fi', ''), false);
    assert.equal(Fuzzy.prefixMatch('fi', null), false);
});

test('prefixMatch handles whitespace splitting, empty queries, and non-string queries', function () {
    assert.equal(Fuzzy.prefixMatch(' fi\tfo\n', 'Firefox\rFocus'), true);
    assert.equal(Fuzzy.prefixMatch('', ''), true);
    assert.equal(Fuzzy.prefixMatch(' \t\n\r ', 12), true);
    assert.equal(Fuzzy.prefixMatch(null, 'Firefox'), true);
});

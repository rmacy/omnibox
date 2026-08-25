// test-jsonc.js — observable behavior tests for js/Jsonc.js.
var fs = require('fs');
var path = require('path');

var src = fs.readFileSync(path.join(__dirname, '..', 'js', 'Jsonc.js'), 'utf8');
var Jsonc = new Function(src + '; return { parse: parse };')();
var checks = 0;
var failures = [];

function check(name, condition) {
    checks++;
    if (!condition) {
        failures.push(name);
    }
}

function equal(name, actual, expected) {
    check(name, JSON.stringify(actual) === JSON.stringify(expected));
}

function throws(name, source, messagePattern) {
    var error = null;
    try {
        Jsonc.parse(source);
    } catch (caught) {
        error = caught;
    }
    check(name + (error ? ' [' + error.message + ']' : ' [did not throw]'),
        error instanceof Error && messagePattern.test(error.message));
}

// Ordinary strict JSON remains ordinary JSON.
equal('strict JSON object', Jsonc.parse('{"ok":true,"nil":null,"items":[1,2,3]}'),
    { ok: true, nil: null, items: [1, 2, 3] });

// Both comment forms are accepted wherever JSON whitespace is accepted.
equal('inline comments', Jsonc.parse('{// heading\n"a": 1, // value\n"b": 2\n}'),
    { a: 1, b: 2 });
equal('block comments', Jsonc.parse('/* before */ {"a": /* middle */ 1} /* after */'),
    { a: 1 });
equal('line comment at end of input', Jsonc.parse('[1, 2] // done'), [1, 2]);

// Comment-looking text inside strings is data, including escaped delimiters.
equal('URL containing line-comment marker',
    Jsonc.parse('{"url":"https://example.test/a//b"}'),
    { url: 'https://example.test/a//b' });
equal('string containing block-comment markers',
    Jsonc.parse('{"text":"not /* a comment */ here"}'),
    { text: 'not /* a comment */ here' });
equal('escaped quotes around comment marker',
    Jsonc.parse('{"text":"say \\"// still text\\""}'),
    { text: 'say "// still text"' });
equal('escaped backslashes remain exact',
    Jsonc.parse('{"path":"C:\\\\tmp\\\\file"}'),
    { path: 'C:\\tmp\\file' });

// Trailing commas work recursively and when comments intervene.
equal('nested object and array trailing commas',
    Jsonc.parse('{"outer":{"items":[1,{"deep":true,},],},}'),
    { outer: { items: [1, { deep: true }] } });
equal('comment after trailing comma',
    Jsonc.parse('{"a":1, /* last property */ }'),
    { a: 1 });
equal('root array trailing comma', Jsonc.parse('[1,2,]'), [1, 2]);

// BOM and Windows newlines do not disturb parsing.
equal('BOM and CRLF',
    Jsonc.parse('\ufeff{\r\n  // comment\r\n  "value": 7,\r\n}\r\n'),
    { value: 7 });

// Values are still interpreted by the native JSON parser.
var numeric = Jsonc.parse('[0,-0,1.25,-2.5e3,6.02e23]');
check('numeric semantics', numeric[0] === 0 && 1 / numeric[1] === -Infinity &&
    numeric[2] === 1.25 && numeric[3] === -2500 && numeric[4] === 6.02e23);
equal('string escape semantics',
    Jsonc.parse('["line\\nfeed","\\u263a","slash\\\\quote\\\""]'),
    ['line\nfeed', '☺', 'slash\\quote"']);

// Invalid JSONC is rejected and reports a usable source location.
throws('missing property value is invalid', '{\n  "a":\n}', /line\s+3,?\s+column\s+1/i);
throws('single-quoted strings are invalid', "{'a': 1}", /line\s+1,?\s+column\s+2/i);
throws('unterminated string is rejected', '{\n  "a": "open',
    /unterminated string.*line\s+2,?\s+column\s+8/i);
throws('unterminated block comment is rejected', '{\r\n  /* open',
    /unterminated block comment.*line\s+2,?\s+column\s+3/i);
throws('malformed array is rejected', '[1,,2]', /invalid JSON.*line\s+1,?\s+column\s+4/i);

if (failures.length > 0) {
    console.error('FAIL (' + failures.length + '/' + checks + '): ' + failures.join('; '));
    process.exit(1);
}

console.log('PASS (' + checks + ' checks)');

// test-jsonc.js — observable behavior tests for js/Jsonc.js.
var test = require('node:test');
var assert = require('node:assert/strict');
var Jsonc = require('../js/Jsonc.js');

function parseError(source) {
    try {
        Jsonc.parse(source);
    } catch (error) {
        return error;
    }
    assert.fail('Expected parsing to fail');
}

function assertParseError(source, pattern) {
    var error = parseError(source);
    assert.ok(error instanceof Error);
    assert.match(error.message, pattern);
}

function withNativeFailure(source, thrown) {
    var original = JSON.parse;
    JSON.parse = function () {
        throw thrown;
    };
    try {
        return parseError(source);
    } finally {
        JSON.parse = original;
    }
}

test('exports the parser and preserves strict JSON values', function () {
    assert.equal(typeof Jsonc.parse, 'function');
    assert.deepEqual(Jsonc.parse('{"ok":true,"no":false,"nil":null,"items":[1,2,3]}'),
        { ok: true, no: false, nil: null, items: [1, 2, 3] });
    assert.deepEqual(Jsonc.parse('{}'), {});
    assert.deepEqual(Jsonc.parse('[]'), []);
});

test('coerces non-string inputs with native JSON semantics', function () {
    assert.equal(Jsonc.parse(12), 12);
    assert.equal(Jsonc.parse(true), true);
    assert.equal(Jsonc.parse(null), null);
    assert.deepEqual(Jsonc.parse({ toString: function () { return '["converted"]'; } }),
        ['converted']);
});

test('accepts LF line comments at token boundaries and end of input', function () {
    assert.deepEqual(Jsonc.parse('// heading\n{\n"a"// key done\n: 1,// value done\n"b":2\n}// eof'),
        { a: 1, b: 2 });
    assert.deepEqual(Jsonc.parse('[1// first\n,2] // done'), [1, 2]);
});

test('accepts CR and CRLF line comments without losing source lines', function () {
    assert.deepEqual(Jsonc.parse('{\r// cr\r"a":1,\r\n// crlf\r\n"b":2\r}'),
        { a: 1, b: 2 });
    assertParseError('{\r\n// hidden\r\n"a" 1}',
        /Expected ':' after property name.*line 3, column 5/i);
});

test('accepts block comments at every whitespace boundary', function () {
    assert.deepEqual(Jsonc.parse('/*before*/{/*name*/"a"/*colon*/:/*value*/1/*comma*/,/*next*/"b":2/*end*/}/*after*/'),
        { a: 1, b: 2 });
    assert.deepEqual(Jsonc.parse('[/* open */1/* middle */,/* next */2/* close */]'), [1, 2]);
});

test('preserves LF, CRLF, and lone CR inside block comments', function () {
    assert.deepEqual(Jsonc.parse('/* one\ntwo\r\nthree\rfour */\n[1]'), [1]);
    assertParseError('/* one\r\ntwo */\r\n[1 2]',
        /Expected ',' or ']'.*line 3, column 4/i);
});

test('keeps comment delimiters and commas inside strings', function () {
    assert.deepEqual(Jsonc.parse('{"url":"https://example.test/a//b","block":"/* data */","punct":",] ,}"}'),
        { url: 'https://example.test/a//b', block: '/* data */', punct: ',] ,}' });
});

test('tracks escaped quotes and backslashes while scanning strings', function () {
    assert.deepEqual(Jsonc.parse('{"quote":"say \\"// text\\"","path":"C:\\\\tmp\\\\file","tail":"\\\\",}'),
        { quote: 'say "// text"', path: 'C:\\tmp\\file', tail: '\\' });
});

test('decodes every simple JSON escape and slash escape', function () {
    assert.deepEqual(Jsonc.parse('["\\\"","\\\\","\\/","\\b","\\f","\\n","\\r","\\t"]'),
        ['"', '\\', '/', '\b', '\f', '\n', '\r', '\t']);
});

test('decodes Unicode escapes with numeric and mixed-case hex digits', function () {
    assert.deepEqual(Jsonc.parse('["\\u0030","\\u00aF","\\u00Af","\\u263A","\\uD83D\\uDE00"]'),
        ['0', '¯', '¯', '☺', '😀']);
});

test('removes trailing commas recursively through comments and whitespace', function () {
    assert.deepEqual(Jsonc.parse('{"outer":{"items":[1,{"deep":true,},/* item */],},/* property */}'),
        { outer: { items: [1, { deep: true }] } });
    assert.deepEqual(Jsonc.parse('[1,2 \t,\r\n]'), [1, 2]);
});

test('does not reinterpret invalid commas as trailing commas', function () {
    assertParseError('[,]', /Expected JSON value.*line 1, column 2/i);
    assertParseError('{,}', /Expected property name.*line 1, column 2/i);
    assertParseError('[1,,]', /Expected JSON value.*line 1, column 4/i);
    assertParseError('{"a":,}', /Expected JSON value.*line 1, column 6/i);
    assertParseError('[1],', /Unexpected token.*line 1, column 4/i);
});

test('parses every valid number form with native number behavior', function () {
    var values = Jsonc.parse('[0,-0,7,-42,1.25,-2.5e3,6.02E23,1e+2,1E-2]');
    assert.equal(values[0], 0);
    assert.equal(1 / values[1], -Infinity);
    assert.deepEqual(values.slice(2), [7, -42, 1.25, -2500, 6.02e23, 100, 0.01]);
});

test('rejects malformed integer forms at their offending digit', function () {
    assertParseError('-', /Expected digit.*line 1, column 2/i);
    assertParseError('-x', /Expected digit.*line 1, column 2/i);
    assertParseError('01', /Leading zero in number.*line 1, column 2/i);
    assertParseError('-09', /Leading zero in number.*line 1, column 3/i);
});

test('rejects malformed fractions and exponents', function () {
    assertParseError('1.', /Expected digit after decimal point.*line 1, column 3/i);
    assertParseError('1.e2', /Expected digit after decimal point.*line 1, column 3/i);
    assertParseError('1e', /Expected digit in exponent.*line 1, column 3/i);
    assertParseError('1E+', /Expected digit in exponent.*line 1, column 4/i);
    assertParseError('1e-x', /Expected digit in exponent.*line 1, column 4/i);
});

test('rejects misspelled and truncated literals at the mismatch', function () {
    assertParseError('truX', /Invalid literal.*line 1, column 4/i);
    assertParseError('fals', /Invalid literal.*line 1, column 5/i);
    assertParseError('nulx', /Invalid literal.*line 1, column 4/i);
});

test('rejects unsupported value syntax and empty sources', function () {
    assertParseError('', /Expected JSON value.*line 1, column 1/i);
    assertParseError('  \t\r\n', /Expected JSON value.*line 2, column 1/i);
    assertParseError("{'a':1}", /Expected property name.*line 1, column 2/i);
    assertParseError('undefined', /Expected JSON value.*line 1, column 1/i);
});

test('rejects invalid string escapes and Unicode escapes', function () {
    assertParseError('"\\x"', /Invalid string escape.*line 1, column 3/i);
    assertParseError('"\\u12x4"', /Invalid Unicode escape.*line 1, column 6/i);
    assertParseError('"\\u123"', /Invalid Unicode escape.*line 1, column 7/i);
});

test('rejects raw control characters in strings', function () {
    assertParseError('"a\tb"', /Unescaped control character.*line 1, column 3/i);
    assertParseError('"a\u0001b"', /Unescaped control character.*line 1, column 3/i);
});

test('reports unterminated strings at their opening quote', function () {
    assertParseError('{\n  "a": "open', /Unterminated string.*line 2, column 8/i);
    assertParseError('["escaped\\\\', /Unterminated string.*line 1, column 2/i);
    assertParseError('["escaped\\', /Unterminated string.*line 1, column 2/i);
    assertParseError('["line\nbreak"]', /Unterminated string.*line 1, column 2/i);
    assertParseError('[\r\n"line\r\nbreak"]', /Unterminated string.*line 2, column 1/i);
});

test('reports unterminated block comments at their opening slash', function () {
    assertParseError('/* open', /Unterminated block comment.*line 1, column 1/i);
    assertParseError('{\r\n  /* open\r\nstill open',
        /Unterminated block comment.*line 2, column 3/i);
});

test('rejects incomplete and malformed arrays', function () {
    assertParseError('[', /Expected JSON value.*line 1, column 2/i);
    assertParseError('[1 2]', /Expected ',' or ']'.*line 1, column 4/i);
    assertParseError('[1,', /Expected JSON value.*line 1, column 4/i);
});

test('rejects incomplete and malformed objects', function () {
    assertParseError('{', /Expected property name.*line 1, column 2/i);
    assertParseError('{"a"}', /Expected ':' after property name.*line 1, column 5/i);
    assertParseError('{"a":}', /Expected JSON value.*line 1, column 6/i);
    assertParseError('{"a":1 "b":2}', /Expected ',' or '}'.*line 1, column 8/i);
    assertParseError('{"a":1,,}', /Expected property name.*line 1, column 8/i);
});

test('reports unexpected content after one complete root value', function () {
    assertParseError('true false', /Unexpected token.*line 1, column 6/i);
    assertParseError('{}\n[]', /Unexpected token.*line 2, column 1/i);
});

test('accepts a BOM only at the document start', function () {
    assert.deepEqual(Jsonc.parse('\ufeff{\r\n// comment\r\n"value":7,\r\n}\r\n'), { value: 7 });
    assertParseError('{}\ufeff', /Unexpected token.*line 1, column 3/i);
});

test('maps native parser position errors back through CRLF', function () {
    var error = withNativeFailure('{\r\n}', new SyntaxError('Unexpected token at position 3'));
    assert.match(error.message, /Invalid JSON: Unexpected token at position 3 at line 2, column 1/i);
});

test('maps native unexpected-end errors to the end of the source', function () {
    var error = withNativeFailure('[\n]', new SyntaxError('Unexpected end of JSON input'));
    assert.match(error.message, /Invalid JSON: Unexpected end of JSON input at line 2, column 2/i);
});

test('preserves native line and column details when supplied', function () {
    var error = withNativeFailure('{}', new SyntaxError('parse failed at line 7 column 9'));
    assert.match(error.message, /Invalid JSON: parse failed at line 7 column 9 at line 7, column 9/i);
});

test('falls back to the first source character for locationless native errors', function () {
    var objectError = withNativeFailure('{}', new SyntaxError('engine-specific failure'));
    var stringError = withNativeFailure('{}', 'plain failure');
    var nullError = withNativeFailure('{}', null);
    assert.match(objectError.message, /engine-specific failure at line 1, column 1/i);
    assert.match(stringError.message, /plain failure at line 1, column 1/i);
    assert.match(nullError.message, /null at line 1, column 1/i);
});

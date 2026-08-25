'use strict';

var testApi = require('node:test');
var test = testApi.test;
var after = testApi.after;
var assert = require('node:assert/strict');
var Calc = require('../js/Calc.js');

var checks = 0;

function equal(actual, expected, message) {
    checks++;
    assert.equal(actual, expected, message);
}

function deepEqual(actual, expected, message) {
    checks++;
    assert.deepEqual(actual, expected, message);
}

function matches(actual, expected, message) {
    checks++;
    assert.match(actual, expected, message);
}

function close(actual, expected, tolerance, message) {
    checks++;
    assert.ok(Math.abs(actual - expected) <= tolerance,
        message || (String(actual) + ' is not within ' + tolerance + ' of ' + expected));
}

function resultOf(expr) {
    var result = Calc.evaluate(expr);
    equal(result.ok, true, String(expr) + ' should evaluate');
    return result;
}

function valueOf(expr) {
    return resultOf(expr).value;
}

function displayOf(expr) {
    return resultOf(expr).display;
}

function fails(expr, errorPattern) {
    var result = Calc.evaluate(expr);
    equal(result.ok, false, String(expr) + ' should fail');
    matches(result.error, errorPattern, String(expr) + ' should report a useful error');
}

test('CommonJS API exports the two public calculator functions', function () {
    deepEqual(Object.keys(Calc).sort(), ['evaluate', 'looksLikeMath']);
    equal(typeof Calc.looksLikeMath, 'function');
    equal(typeof Calc.evaluate, 'function');
});

test('looksLikeMath rejects non-math queries and recognizes every signal form', function () {
    equal(Calc.looksLikeMath(null), false);
    equal(Calc.looksLikeMath(42), false);
    equal(Calc.looksLikeMath('   '), false);
    equal(Calc.looksLikeMath('1\n+2'), false);
    equal(Calc.looksLikeMath('1\r+2'), false);
    equal(Calc.looksLikeMath('>1+2'), false);
    equal(Calc.looksLikeMath('= anything'), true);
    equal(Calc.looksLikeMath('1984'), false);
    equal(Calc.looksLikeMath('firefox'), false);
    equal(Calc.looksLikeMath('sqrt'), false);
    equal(Calc.looksLikeMath('2 widgets'), false);

    ['1+2', '1-2', '1*2', '1/2', '50%', '2^3', '(2)', '2×3', '6÷2',
        '2−1', '√9', '2²', '2³'].forEach(function (query) {
        equal(Calc.looksLikeMath(query), true, query + ' should look mathematical');
    });
    equal(Calc.looksLikeMath('2pi'), true);
    equal(Calc.looksLikeMath('2SIN30'), true);
    equal(Calc.looksLikeMath('9 unknown pi'), true);
});

test('normalization handles Unicode, aliases, case, whitespace, decimals, exponents, and grouped digits', function () {
    equal(valueOf(' =  2 × 3 + 8 ÷ 4 '), 8);
    equal(valueOf('5 − 8'), -3);
    equal(valueOf('3² + 2³'), 17);
    equal(valueOf('√81'), 9);
    equal(valueOf('2**3'), 8);
    equal(valueOf('SQRT(16)'), 4);
    equal(valueOf('.5 + 1.'), 1.5);
    equal(valueOf('1e3 + 2E+2 + 4e-1'), 1200.4);
    equal(valueOf('1,234,567 + 1'), 1234568);
    equal(valueOf('(1,000) + 1'), 1001);

    // In function argument position commas are separators, not digit grouping.
    equal(valueOf('min(1,000)'), 0);
    equal(valueOf('max(1,2,000)'), 2);
});

test('operators obey precedence, associativity, unary rules, and implicit multiplication', function () {
    equal(valueOf('2+3*4'), 14);
    equal(valueOf('(2+3)*4'), 20);
    equal(valueOf('20/5*2-3+1'), 6);
    equal(valueOf('2^3^2'), 512);
    equal(valueOf('-2^2'), -4);
    equal(valueOf('(-2)^2'), 4);
    equal(valueOf('2^-3'), 0.125);
    equal(valueOf('+--3'), 3);
    equal(valueOf('2pi'), 2 * Math.PI);
    equal(valueOf('2e'), 2 * Math.E);
    equal(valueOf('2(3+4)'), 14);
    equal(valueOf('(2)(3)'), 6);
    equal(valueOf('3sqrt(9)'), 9);
    equal(valueOf('2 3'), 6);
    equal(valueOf('sqrt2'), Math.sqrt(2));
    close(valueOf('sin30'), 0.5, 1e-12);
    equal(valueOf('pi2'), 2 * Math.PI);
});

test('postfix percent and percent-of bind to the intended operand', function () {
    equal(valueOf('50%'), 0.5);
    equal(valueOf('(25+25)%'), 0.5);
    equal(valueOf('10% of 200'), 20);
    equal(valueOf('10% of -200'), -20);
    equal(valueOf('2 * 10% of 50'), 10);
    close(valueOf('100-10%'), 99.9, 1e-12);
    fails('2 of 3', /Unexpected "of"/);
    fails('of', /Unexpected "of"/);
    fails('50%%', /Unexpected "%"/);
});

test('constants and every supported mathematical function evaluate correctly', function () {
    close(valueOf('pi'), Math.PI, 0);
    close(valueOf('tau'), 2 * Math.PI, 0);
    close(valueOf('e'), Math.E, 0);

    close(valueOf('sin(30)'), 0.5, 1e-12);
    close(valueOf('cos(60)'), 0.5, 1e-12);
    close(valueOf('tan(45)'), 1, 1e-12);
    close(valueOf('asin(1)'), 90, 1e-12);
    close(valueOf('acos(0)'), 90, 1e-12);
    close(valueOf('atan(1)'), 45, 1e-12);
    close(valueOf('sinh(1)'), Math.sinh(1), 1e-12);
    close(valueOf('cosh(1)'), Math.cosh(1), 1e-12);
    close(valueOf('tanh(1)'), Math.tanh(1), 1e-12);

    equal(valueOf('sqrt 9'), 3);
    close(valueOf('cbrt(8)'), 2, 1e-12);
    close(valueOf('cbrt(-8)'), -2, 1e-12);
    equal(valueOf('abs(-7)'), 7);
    close(valueOf('ln(e)'), 1, 1e-12);
    equal(valueOf('log2(8)'), 3);
    equal(valueOf('log10(1000)'), 3);
    equal(valueOf('log(1000)'), 3);
    close(valueOf('exp(1)'), Math.E, 1e-12);
    equal(valueOf('floor(2.9)'), 2);
    equal(valueOf('ceil(2.1)'), 3);
    equal(valueOf('round(2.5)'), 3);
    equal(valueOf('trunc(2.9)'), 2);
    equal(valueOf('trunc(-2.9)'), -2);
    equal(valueOf('mod(10,3)'), 1);
    equal(valueOf('pow(2,10)'), 1024);
    equal(valueOf('min(3,1,2)'), 1);
    equal(valueOf('max(1,3,2)'), 3);
    equal(valueOf('avg(2,4,9)'), 5);
});

test('logarithms retain their ES5-compatible fallback behavior', function () {
    var nativeLog2 = Math.log2;
    var nativeLog10 = Math.log10;
    var log2Result;
    var log10Result;
    var logResult;
    try {
        Math.log2 = undefined;
        Math.log10 = undefined;
        log2Result = Calc.evaluate('log2(8)');
        log10Result = Calc.evaluate('log10(1000)');
        logResult = Calc.evaluate('log(100)');
    } finally {
        Math.log2 = nativeLog2;
        Math.log10 = nativeLog10;
    }
    equal(log2Result.ok, true);
    close(log2Result.value, 3, 1e-12);
    equal(log10Result.ok, true);
    close(log10Result.value, 3, 1e-12);
    equal(logResult.ok, true);
    close(logResult.value, 2, 1e-12);
});

test('arity and malformed argument lists fail rather than being guessed', function () {
    fails('sqrt()', /expects 1 argument/);
    fails('sqrt(1,2)', /expects 1 argument/);
    fails('pow(2)', /expects 2 arguments/);
    fails('pow(2,3,4)', /expects 2 arguments/);
    fails('pow 2', /expects 2 arguments/);
    fails('min()', /expects at least 2 arguments/);
    fails('max(1)', /expects at least 2 arguments/);
    fails('avg(1)', /expects at least 2 arguments/);
    fails('pow(2 3)', /expects 2 arguments/);
    fails('pow(2,,3)', /Unexpected ","/);
    fails('pow(2%%,3)', /Expected "," or "\)"/);
    fails('pow(2;3)', /Unexpected character ";"/);
});

test('invalid expressions report tokenizer, parser, and finite-result failures', function () {
    fails(null, /Expression must be a string/);
    fails('', /Empty expression/);
    fails(' = ', /Empty expression/);
    fails('.', /Unexpected character "\."/);
    fails('1@2', /Unexpected character "@"/);
    fails('1e999', /Invalid number/);
    fails('foo(3)', /Unknown identifier "foo"/);
    fails('(1+2', /Missing closing parenthesis/);
    fails('1+', /Unexpected end of expression/);
    fails(')', /Unexpected "\)"/);
    fails('1)', /Unexpected "\)"/);
    fails('1e+', /Unexpected end of expression/);
    fails('1/0', /not a finite number/);
    fails('0/0', /not a finite number/);
    fails('sqrt(-1)', /not a finite number/);
    fails('exp(1000)', /not a finite number/);
    fails('pow(-1,0.5)', /not a finite number/);
});

test('display formatting covers integers, fractions, exponents, rounding, carry, and negative zero', function () {
    equal(displayOf('0'), '0');
    var negativeZero = resultOf('-0');
    equal(Object.is(negativeZero.value, -0), true);
    equal(negativeZero.display, '0');
    equal(displayOf('1234567'), '1,234,567');
    equal(displayOf('-1234567'), '-1,234,567');
    equal(displayOf('2^50'), '1,125,899,906,842,624');
    equal(displayOf('123.45'), '123.45');
    equal(displayOf('0.1+0.2'), '0.3');
    equal(displayOf('1/3'), '0.3333333333');
    equal(displayOf('2/3'), '0.6666666667');
    equal(displayOf('1.23456789044'), '1.23456789');
    equal(displayOf('1.23456789056'), '1.234567891');
    equal(displayOf('-1.23456789056'), '-1.234567891');
    equal(displayOf('99999999995000000'), '100,000,000,000,000,000');
    equal(displayOf('1e16'), '10,000,000,000,000,000');
    equal(displayOf('1e20'), '100,000,000,000,000,000,000');
    equal(displayOf('1e-7'), '0.0000001');
    equal(displayOf('1e-20'), '0.00000000000000000001');
    equal(displayOf('-1e-20'), '-0.00000000000000000001');
    equal(displayOf('1e100'), '10' + ',000'.repeat(33));
});

after(function () {
    console.log(checks + ' behavior checks passed');
});

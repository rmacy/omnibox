// tests/test-calc.js — node test harness for js/Calc.js (run: node tests/test-calc.js)
'use strict';

var fs = require('fs');
var path = require('path');

var src = fs.readFileSync(path.join(__dirname, '..', 'js', 'Calc.js'), 'utf8');
var Calc = new Function(src + '; return {looksLikeMath: looksLikeMath, evaluate: evaluate};')();

var failures = 0;
var checks = 0;

function ok(name, cond) {
    checks++;
    if (cond) {
        console.log('PASS ' + name);
    } else {
        failures++;
        console.log('FAIL ' + name);
    }
}

function val(expr) {
    var r = Calc.evaluate(expr);
    return r.ok ? r.value : NaN;
}

function near(a, b) {
    return Math.abs(a - b) <= 1e-9;
}

function disp(expr) {
    var r = Calc.evaluate(expr);
    return r.ok ? r.display : '<error: ' + r.error + '>';
}

function evalFails(expr) {
    var r = Calc.evaluate(expr);
    return r.ok === false;
}

// --- value evaluation ---
ok("evaluate('1+2') = 3", val('1+2') === 3);
ok("evaluate('2*3+4') = 10", val('2*3+4') === 10);
ok("evaluate('2+3*4') = 14", val('2+3*4') === 14);
ok("evaluate('(2+3)*4') = 20", val('(2+3)*4') === 20);
ok("evaluate('2^10') = 1024", val('2^10') === 1024);
ok("evaluate('2^3^2') = 512 (right-assoc ^)", val('2^3^2') === 512);
ok("evaluate('-5+3') = -2", val('-5+3') === -2);
ok("evaluate('10/4') = 2.5", val('10/4') === 2.5);
ok("evaluate('50%') = 0.5", val('50%') === 0.5);
ok("evaluate('1,000+1') = 1001", val('1,000+1') === 1001);
ok("evaluate('sqrt(16)') = 4", val('sqrt(16)') === 4);
ok("evaluate('sin(30)') ≈ 0.5 (degrees)", near(val('sin(30)'), 0.5));
ok("evaluate('log(100)') = 2", val('log(100)') === 2);
ok("evaluate('ln(e)') = 1", near(val('ln(e)'), 1));
ok("evaluate('2pi') ≈ 6.283185307179586", near(val('2pi'), 6.283185307179586));
ok("evaluate('2(3+4)') = 14", val('2(3+4)') === 14);
ok("evaluate('3sqrt(9)') = 9", val('3sqrt(9)') === 9);
ok("evaluate('min(3,1,2)') = 1", val('min(3,1,2)') === 1);
ok("evaluate('avg(2,4,6)') = 4", val('avg(2,4,6)') === 4);
ok("evaluate('mod(10,3)') = 1", val('mod(10,3)') === 1);
ok("evaluate('10% of 200') = 20", val('10% of 200') === 20);
ok("evaluate('=7*6') = 42", val('=7*6') === 42);
ok("evaluate('1e3+1') = 1001", val('1e3+1') === 1001);
ok("evaluate('round(2.4)') = 2", val('round(2.4)') === 2);
ok("evaluate('100-10%') = 99.9", near(val('100-10%'), 99.9));

// --- looksLikeMath ---
ok("looksLikeMath('1+2') = true", Calc.looksLikeMath('1+2') === true);
ok("looksLikeMath('=5') = true", Calc.looksLikeMath('=5') === true);
ok("looksLikeMath('1984') = false", Calc.looksLikeMath('1984') === false);
ok("looksLikeMath('firefox') = false", Calc.looksLikeMath('firefox') === false);
ok("looksLikeMath('>ls') = false", Calc.looksLikeMath('>ls') === false);
ok("looksLikeMath('2pi') = true", Calc.looksLikeMath('2pi') === true);
ok("looksLikeMath('50%') = true", Calc.looksLikeMath('50%') === true);
ok("looksLikeMath('') = false", Calc.looksLikeMath('') === false);

// --- evaluate failures ---
ok("evaluate('1/0') fails", evalFails('1/0'));
ok("evaluate('foo(3)') fails", evalFails('foo(3)'));
ok("evaluate('(1+2') fails", evalFails('(1+2'));
ok("evaluate('') fails", evalFails(''));

// --- display formatting ---
ok("display('1234567') = '1,234,567'", disp('1234567') === '1,234,567');
ok("display('0.1+0.2') = '0.3'", disp('0.1+0.2') === '0.3');
ok("display('2^50') = '1,125,899,906,842,624'", disp('2^50') === '1,125,899,906,842,624');
ok("display('-0.5+0.5') = '0'", disp('-0.5+0.5') === '0');

console.log('');
console.log((checks - failures) + '/' + checks + ' checks passed');
if (failures > 0) {
    console.log(failures + ' FAILURE(S)');
    process.exit(1);
}
console.log('ALL PASS');
process.exit(0);

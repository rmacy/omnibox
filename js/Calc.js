// Calc.js — Omnibox calculator: expression evaluation for the launcher (pure ES5, no eval/Function).
//
// Supported syntax: numbers with decimals, leading dot (.5), scientific notation (1e3) and
// digit-grouping commas (1,000); operators + - * / ^ % with usual precedence where ^ is
// right-associative and binds tighter than unary minus, which binds tighter than * and /, plus
// the spellings × -> *, ÷ -> /, − -> -, ** -> ^, ² -> ^2, ³ -> ^3 and √ -> sqrt; constants pi,
// tau and e; postfix percent dividing the preceding number or paren group by 100 (50% = 0.5)
// and the "<a>% of <b>" pattern (10% of 200 = 20); implicit multiplication (2pi, 2(3+4),
// (2)(3), 3sqrt(9), 2e); functions sin cos tan asin acos atan sinh cosh tanh (trig in degrees),
// sqrt cbrt abs ln log2 log10 log exp floor ceil round trunc, two-argument mod(a,b) and
// pow(a,b), and variadic min/max/avg (two or more comma-separated arguments); a leading '=' is
// accepted and ignored. Public API: looksLikeMath(query) -> boolean decides whether the query
// should surface the calculator row; evaluate(expr) -> {ok:true, value, display} or
// {ok:false, error}. Display formatting: exact integers below 1e16 get comma thousands
// separators; everything else is rounded to 10 significant digits with trailing zeros stripped
// and is always written in plain decimal notation (never exponential), with separators on the
// integer part; '-0' is never emitted.

// Names recognized by looksLikeMath (function names and constants).
var CALC_WORDS = {
    sin: true, cos: true, tan: true, asin: true, acos: true, atan: true,
    sinh: true, cosh: true, tanh: true, sqrt: true, cbrt: true, abs: true,
    ln: true, log2: true, log10: true, log: true, exp: true, floor: true,
    ceil: true, round: true, trunc: true, min: true, max: true, avg: true,
    mod: true, pow: true, pi: true, tau: true, e: true
};

// Arity of each function: 1 = exactly one, 2 = exactly two, -1 = two or more.
var CALC_ARITY = {
    sin: 1, cos: 1, tan: 1, asin: 1, acos: 1, atan: 1, sinh: 1, cosh: 1,
    tanh: 1, sqrt: 1, cbrt: 1, abs: 1, ln: 1, log2: 1, log10: 1, log: 1,
    exp: 1, floor: 1, ceil: 1, round: 1, trunc: 1, mod: 2, pow: 2,
    min: -1, max: -1, avg: -1
};

// ---------------------------------------------------------------------------
// Public: heuristic "does this query look like a math expression?"
// ---------------------------------------------------------------------------
function looksLikeMath(query) {
    if (typeof query !== 'string') return false;
    var q = query.trim();
    if (q.length === 0) return false;
    if (q.indexOf('\n') !== -1 || q.indexOf('\r') !== -1) return false;
    if (q.charAt(0) === '>') return false; // run-command prefix wins
    if (q.charAt(0) === '=') return true;  // explicit calculation request
    var hasDigit = false;
    var hasSignal = false;
    var i, ch;
    for (i = 0; i < q.length; i++) {
        ch = q.charAt(i);
        if (ch >= '0' && ch <= '9') {
            hasDigit = true;
        } else if (ch === '+' || ch === '-' || ch === '*' || ch === '/' ||
                   ch === '%' || ch === '^' || ch === '(' ||
                   ch === '\u00d7' || ch === '\u00f7' || ch === '\u2212' ||
                   ch === '\u221a' || ch === '\u00b2' || ch === '\u00b3') {
            hasSignal = true;
        }
    }
    if (!hasDigit) return false;
    if (hasSignal) return true; // covers operators, '(' and "<a>% of <b>"
    // Bare words: accept when a letter run is a known function or constant
    // (catches implicit multiplication forms like "2pi").
    var lower = q.toLowerCase();
    var run = '';
    for (i = 0; i <= lower.length; i++) {
        ch = i < lower.length ? lower.charAt(i) : '';
        if (ch >= 'a' && ch <= 'z') {
            run += ch;
        } else {
            if (run !== '' && CALC_WORDS[run]) return true;
            run = '';
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Public: evaluate an expression.
// Returns {ok:true, value:<number>, display:<string>} or {ok:false, error:<string>}.
// ---------------------------------------------------------------------------
function evaluate(rawExpr) {
    try {
        var src = calcNormalize(rawExpr);
        var toks = calcTokenize(src);
        var pos = { i: 0 };
        var value = calcParseAdd(toks, pos);
        if (pos.i < toks.length) {
            calcFail('Unexpected "' + calcTokLabel(toks[pos.i]) + '"');
        }
        if (!isFinite(value)) {
            return { ok: false, error: 'Result is not a finite number' };
        }
        return { ok: true, value: value, display: calcFormat(value) };
    } catch (err) {
        var msg = (err && err.message) ? err.message : 'Invalid expression';
        return { ok: false, error: msg };
    }
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------
function calcFail(msg) {
    throw { message: msg };
}

function calcNormalize(raw) {
    if (typeof raw !== 'string') calcFail('Expression must be a string');
    var s = raw.trim();
    if (s.charAt(0) === '=') s = s.slice(1).trim();
    if (s.length === 0) calcFail('Empty expression');
    var out = '';
    var i, ch;
    for (i = 0; i < s.length; i++) {
        ch = s.charAt(i);
        if (ch === '\u00d7') out += '*';        // ×
        else if (ch === '\u00f7') out += '/';   // ÷
        else if (ch === '\u2212') out += '-';   // −
        else if (ch === '\u00b2') out += '^2';  // ²
        else if (ch === '\u00b3') out += '^3';  // ³
        else if (ch === '\u221a') out += 'sqrt'; // √
        else out += ch;
    }
    s = out.replace(/\*\*/g, '^');
    s = s.toLowerCase();
    // Strip digit-grouping commas (1,000 -> 1000, 12,345,678 -> 12345678), but keep
    // argument commas inside function calls: a comma after another comma is always
    // a separator, and a comma right after '(' is a separator only when a letter
    // (a function name) precedes that '(' — otherwise '(1,000)' is grouping.
    s = s.replace(/\d{1,3}(?:,\d{3})+(?!\d)/g, function (match, off, full) {
        var before = off > 0 ? full.charAt(off - 1) : '';
        if (before === ',') return match;
        if (before === '(' && off > 1) {
            var beforeParen = full.charAt(off - 2);
            if ((beforeParen >= 'a' && beforeParen <= 'z') ||
                (beforeParen >= 'A' && beforeParen <= 'Z')) return match;
        }
        return match.replace(/,/g, '');
    });
    return s;
}

// ---------------------------------------------------------------------------
// Tokenizer
function calcKnownName(name) {
    return Object.prototype.hasOwnProperty.call(CALC_ARITY, name) ||
        Object.prototype.hasOwnProperty.call(CALC_WORDS, name);
}

// ---------------------------------------------------------------------------
function calcTokenize(s) {
    var toks = [];
    var n = s.length;
    var i = 0, j, k, ch;
    while (i < n) {
        ch = s.charAt(i);
        if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') { i++; continue; }
        var isDigit = ch >= '0' && ch <= '9';
        var isDotNumber = ch === '.' && i + 1 < n && s.charAt(i + 1) >= '0' && s.charAt(i + 1) <= '9';
        if (isDigit || isDotNumber) {
            j = i;
            while (j < n && s.charAt(j) >= '0' && s.charAt(j) <= '9') j++;
            if (j < n && s.charAt(j) === '.') {
                j++;
                while (j < n && s.charAt(j) >= '0' && s.charAt(j) <= '9') j++;
            }
            // Exponent part only when 'e' is followed by a digit (or sign then digit);
            // otherwise the letters belong to a following identifier ('2e' = 2*e).
            if (j < n && s.charAt(j) === 'e') {
                k = j + 1;
                if (k < n && (s.charAt(k) === '+' || s.charAt(k) === '-')) k++;
                if (k < n && s.charAt(k) >= '0' && s.charAt(k) <= '9') {
                    j = k;
                    while (j < n && s.charAt(j) >= '0' && s.charAt(j) <= '9') j++;
                }
            }
            var numStr = s.slice(i, j);
            var numVal = parseFloat(numStr);
            if (!isFinite(numVal)) calcFail('Invalid number "' + numStr + '"');
            toks.push({ type: 'num', value: numVal });
            i = j;
            continue;
        }
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
            j = i;
            while (j < n) {
                var c2 = s.charAt(j);
                if ((c2 >= 'a' && c2 <= 'z') || (c2 >= 'A' && c2 <= 'Z') ||
                    (j > i && c2 >= '0' && c2 <= '9')) j++;
                else break;
            }
            var name = s.slice(i, j).toLowerCase();
            if (calcKnownName(name)) {
                toks.push({ type: 'ident', name: name });
                i = j;
            } else {
                // Unknown run: split off the longest known-name prefix so that
                // sqrt2 -> sqrt 2, sin30 -> sin 30, pi2 -> pi 2.
                var pLen = 0;
                for (var len = name.length - 1; len >= 1; len--) {
                    if (calcKnownName(name.slice(0, len))) { pLen = len; break; }
                }
                if (pLen > 0) {
                    toks.push({ type: 'ident', name: name.slice(0, pLen) });
                    i = i + pLen; // rescan the remainder (digits or another name)
                } else {
                    toks.push({ type: 'ident', name: name });
                    i = j;
                }
            }
            continue;
        }
        if (ch === '+' || ch === '-' || ch === '*' || ch === '/' || ch === '^' ||
            ch === '%' || ch === '(' || ch === ')' || ch === ',') {
            toks.push({ type: 'op', op: ch });
            i++;
            continue;
        }
        calcFail('Unexpected character "' + ch + '"');
    }
    return toks;
}

function calcTokLabel(t) {
    if (t === null) return 'end of expression';
    if (t.type === 'num') return String(t.value);
    if (t.type === 'ident') return t.name;
    return t.op;
}

// ---------------------------------------------------------------------------
// Parser (recursive descent).
// Precedence, loosest to tightest: + - | * / and implicit multiplication |
// unary + - | ^ (right-assoc) | postfix % | atoms.
// ---------------------------------------------------------------------------
function calcPeek(toks, pos) {
    return pos.i < toks.length ? toks[pos.i] : null;
}

function calcIsOp(t, op) {
    return t !== null && t.type === 'op' && t.op === op;
}

function calcParseAdd(toks, pos) {
    var v = calcParseMul(toks, pos);
    var t, r;
    for (;;) {
        t = calcPeek(toks, pos);
        if (!calcIsOp(t, '+') && !calcIsOp(t, '-')) break;
        pos.i++;
        r = calcParseMul(toks, pos);
        v = t.op === '+' ? v + r : v - r;
    }
    return v;
}

function calcParseMul(toks, pos) {
    var v = calcParseUnary(toks, pos);
    var t, r;
    for (;;) {
        t = calcPeek(toks, pos);
        if (calcIsOp(t, '*') || calcIsOp(t, '/')) {
            pos.i++;
            r = calcParseUnary(toks, pos);
            v = t.op === '*' ? v * r : v / r;
        } else if (t !== null && (t.type === 'num' || t.type === 'ident' || calcIsOp(t, '('))) {
            // Implicit multiplication: 2pi, 2(3+4), (2)(3), 3sqrt(9)
            r = calcParseUnary(toks, pos);
            v = v * r;
        } else {
            break;
        }
    }
    return v;
}

function calcParseUnary(toks, pos) {
    var t = calcPeek(toks, pos);
    if (calcIsOp(t, '-')) {
        pos.i++;
        return -calcParseUnary(toks, pos);
    }
    if (calcIsOp(t, '+')) {
        pos.i++;
        return calcParseUnary(toks, pos);
    }
    return calcParsePower(toks, pos);
}

function calcParsePower(toks, pos) {
    var base = calcParsePostfix(toks, pos);
    if (calcIsOp(calcPeek(toks, pos), '^')) {
        pos.i++;
        var ex = calcParseUnary(toks, pos); // right-associative; allows 2^-3
        return Math.pow(base, ex);
    }
    return base;
}

function calcParsePostfix(toks, pos) {
    var v = calcParseAtom(toks, pos);
    var hadPercent = false;
    if (calcIsOp(calcPeek(toks, pos), '%')) {
        pos.i++;
        v = v / 100; // postfix %: binds to the number or paren group only
        hadPercent = true;
    }
    var t = calcPeek(toks, pos);
    if (t !== null && t.type === 'ident' && t.name === 'of') {
        if (!hadPercent) calcFail('Unexpected "of" (expected "<a>% of <b>")');
        pos.i++;
        var r = calcParseUnary(toks, pos);
        v = v * r;
    }
    return v;
}

function calcParseAtom(toks, pos) {
    var t = calcPeek(toks, pos);
    if (t === null) calcFail('Unexpected end of expression');
    if (t.type === 'num') {
        pos.i++;
        return t.value;
    }
    if (calcIsOp(t, '(')) {
        pos.i++;
        var v = calcParseAdd(toks, pos);
        if (!calcIsOp(calcPeek(toks, pos), ')')) calcFail('Missing closing parenthesis');
        pos.i++;
        return v;
    }
    if (t.type === 'ident') {
        pos.i++;
        var name = t.name;
        if (name === 'pi') return Math.PI;
        if (name === 'tau') return 2 * Math.PI;
        if (name === 'e') return Math.E;
        if (name === 'of') calcFail('Unexpected "of"');
        return calcCallFunction(name, toks, pos);
    }
    calcFail('Unexpected "' + calcTokLabel(t) + '"');
}

function calcCallFunction(name, toks, pos) {
    if (!Object.prototype.hasOwnProperty.call(CALC_ARITY, name)) {
        calcFail('Unknown identifier "' + name + '"');
    }
    var arity = CALC_ARITY[name];
    var args = [];
    if (calcIsOp(calcPeek(toks, pos), '(')) {
        pos.i++;
        if (!calcIsOp(calcPeek(toks, pos), ')')) {
            for (;;) {
                args.push(calcParseAdd(toks, pos));
                if (calcIsOp(calcPeek(toks, pos), ',')) { pos.i++; continue; }
                if (calcIsOp(calcPeek(toks, pos), ')')) { break; }
                calcFail('Expected "," or ")" in arguments of ' + name);
            }
        }
        pos.i++;
    } else {
        // Paren-less application for a single operand: sqrt 9, √9, sin 30
        args.push(calcParsePostfix(toks, pos));
    }
    if (arity === 1 && args.length !== 1) calcFail(name + '() expects 1 argument');
    if (arity === 2 && args.length !== 2) calcFail(name + '() expects 2 arguments');
    if (arity === -1 && args.length < 2) calcFail(name + '() expects at least 2 arguments');
    var a = args[0];
    var b = args.length > 1 ? args[1] : 0;
    var deg = Math.PI / 180;
    var r, i, sum;
    switch (name) {
    case 'sin': return Math.sin(a * deg);
    case 'cos': return Math.cos(a * deg);
    case 'tan': return Math.tan(a * deg);
    case 'asin': return Math.asin(a) / deg;
    case 'acos': return Math.acos(a) / deg;
    case 'atan': return Math.atan(a) / deg;
    case 'sinh': r = Math.exp(a); return (r - 1 / r) / 2;
    case 'cosh': r = Math.exp(a); return (r + 1 / r) / 2;
    case 'tanh': r = Math.exp(a); return (r - 1 / r) / (r + 1 / r);
    case 'sqrt': return Math.sqrt(a);
    case 'cbrt': return a < 0 ? -Math.pow(-a, 1 / 3) : Math.pow(a, 1 / 3);
    case 'abs': return Math.abs(a);
    case 'ln': return Math.log(a);
    case 'log2':
        return typeof Math.log2 === 'function' ? Math.log2(a) : Math.log(a) / Math.LN2;
    case 'log10':
    case 'log':
        return typeof Math.log10 === 'function' ? Math.log10(a) : Math.log(a) / Math.LN10;
    case 'exp': return Math.exp(a);
    case 'floor': return Math.floor(a);
    case 'ceil': return Math.ceil(a);
    case 'round': return Math.round(a);
    case 'trunc': return a < 0 ? Math.ceil(a) : Math.floor(a);
    case 'mod': return a % b;
    case 'pow': return Math.pow(a, b);
    case 'min':
        r = a;
        for (i = 1; i < args.length; i++) if (args[i] < r) r = args[i];
        return r;
    case 'max':
        r = a;
        for (i = 1; i < args.length; i++) if (args[i] > r) r = args[i];
        return r;
    case 'avg':
        sum = 0;
        for (i = 0; i < args.length; i++) sum += args[i];
        return sum / args.length;
    }
    calcFail('Unknown identifier "' + name + '"');
}

// ---------------------------------------------------------------------------
// Display formatting
// ---------------------------------------------------------------------------
function calcCommas(intStr) {
    var out = '';
    var n = intStr.length;
    for (var i = 0; i < n; i++) {
        if (i > 0 && (n - i) % 3 === 0) out += ',';
        out += intStr.charAt(i);
    }
    return out;
}

// Extract the significant digits of a positive finite number from its shortest
// JS string form (plain or exponential). Returns { d: <digits>, e: <power of
// ten such that value = 0.d * 10^e> }.
function calcDigits(a) {
    var s = String(a);
    var mant = s;
    var expStr = '';
    var ePos = s.indexOf('e');
    if (ePos === -1) ePos = s.indexOf('E');
    if (ePos !== -1) {
        mant = s.slice(0, ePos);
        expStr = s.slice(ePos + 1);
    }
    var digits = '';
    var intLen = 0;
    var dotSeen = false;
    var i, ch;
    for (i = 0; i < mant.length; i++) {
        ch = mant.charAt(i);
        if (ch === '.') { dotSeen = true; continue; }
        if (ch === '-' || ch === '+') continue;
        digits += ch;
        if (!dotSeen) intLen++;
    }
    var lz = 0;
    while (lz < digits.length && digits.charAt(lz) === '0') lz++;
    digits = digits.slice(lz);
    var e = intLen - lz;
    if (expStr !== '') e += parseInt(expStr, 10);
    if (digits === '') digits = '0';
    return { d: digits, e: e };
}

// Round a digit string to 10 significant digits, carrying overflow into the
// exponent. Returns { d, e } with the same 0.d * 10^e meaning.
function calcRound10(digits, e) {
    if (digits.length <= 10) return { d: digits, e: e };
    var keep = digits.slice(0, 10);
    if (digits.charAt(10) >= '5') {
        var arr = keep.split('');
        var i = arr.length - 1;
        var carry = 1;
        while (i >= 0 && carry) {
            var d9 = arr[i].charCodeAt(0) - 48 + carry;
            if (d9 >= 10) { arr[i] = '0'; carry = 1; }
            else { arr[i] = String(d9); carry = 0; }
            i--;
        }
        if (carry) {
            arr.unshift('1');
            e += 1;
        }
        keep = arr.join('');
    }
    return { d: keep, e: e };
}

// Build a plain decimal string from digits d and exponent e (value = 0.d*10^e),
// with comma separators on the integer part and no trailing zeros or dot.
function calcBuild(d, e, sign) {
    var intPart, fracPart, zeros;
    if (e >= d.length) {
        intPart = d;
        zeros = e - d.length;
        while (zeros > 0) { intPart += '0'; zeros--; }
        fracPart = '';
    } else if (e > 0) {
        intPart = d.slice(0, e);
        fracPart = d.slice(e);
    } else {
        intPart = '0';
        fracPart = '';
        zeros = -e;
        while (zeros > 0) { fracPart += '0'; zeros--; }
        fracPart += d;
    }
    var out = sign + calcCommas(intPart);
    if (fracPart !== '') out += '.' + fracPart;
    return out;
}

function calcFormat(v) {
    if (v === 0) return '0'; // also catches -0
    var sign = v < 0 ? '-' : '';
    var a = v < 0 ? -v : v;
    // Exact integers below 1e16 are printed in full with separators.
    if (a === Math.floor(a) && a < 1e16) {
        return sign + calcCommas(String(a));
    }
    var dg = calcDigits(a);
    var rd = calcRound10(dg.d, dg.e);
    var d = rd.d;
    while (d.length > 1 && d.charAt(d.length - 1) === '0') d = d.slice(0, d.length - 1);
    return calcBuild(d, rd.e, sign);
}

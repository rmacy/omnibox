// Jsonc.js — JSON with comments and trailing commas (pure ES5 for Qt V4).
//
// parse(raw) -> the parsed JSON value. Comments and trailing commas are
// removed without changing source offsets, so parse errors can retain useful
// line and column information.

function jsoncLocation(text, position) {
    var line = 1;
    var column = 1;
    var i = 0;
    var c;

    while (i < position && i < text.length) {
        c = text.charAt(i);
        if (c === '\r') {
            if (i + 1 < position && text.charAt(i + 1) === '\n') {
                i++;
            }
            line++;
            column = 1;
        } else if (c === '\n') {
            line++;
            column = 1;
        } else {
            column++;
        }
        i++;
    }

    return { line: line, column: column };
}

function jsoncError(message, line, column) {
    return new Error(message + ' at line ' + line + ', column ' + column);
}

function jsoncStripComments(raw) {
    var out = [];
    var state = 0; // 0 normal, 1 string, 2 line comment, 3 block comment
    var escaped = false;
    var startLine = 1;
    var startColumn = 1;
    var line = 1;
    var column = 1;
    var i;
    var c;
    var next;

    for (i = 0; i < raw.length; i++) {
        c = raw.charAt(i);
        next = i + 1 < raw.length ? raw.charAt(i + 1) : '';

        if (state === 0) {
            if (c === '"') {
                state = 1;
                escaped = false;
                startLine = line;
                startColumn = column;
                out.push(c);
            } else if (c === '/' && next === '/') {
                state = 2;
                out.push(' ');
                out.push(' ');
                i++;
                column++;
            } else if (c === '/' && next === '*') {
                state = 3;
                startLine = line;
                startColumn = column;
                out.push(' ');
                out.push(' ');
                i++;
                column++;
            } else {
                out.push(c);
            }
        } else if (state === 1) {
            out.push(c);
            if (escaped) {
                escaped = false;
            } else if (c === '\\') {
                escaped = true;
            } else if (c === '"') {
                state = 0;
            } else if (c === '\r' || c === '\n') {
                throw jsoncError('Unterminated string', startLine, startColumn);
            }
        } else if (state === 2) {
            if (c === '\r' || c === '\n') {
                state = 0;
                out.push(c);
            } else {
                out.push(' ');
            }
        } else {
            if (c === '*' && next === '/') {
                out.push(' ');
                out.push(' ');
                i++;
                column++;
                state = 0;
            } else if (c === '\r' || c === '\n') {
                out.push(c);
            } else {
                out.push(' ');
            }
        }

        if (c === '\r') {
            if (next === '\n') {
                // The following LF will advance through the loop but should
                // not count as a second source line.
                line++;
                column = 0;
            } else {
                line++;
                column = 0;
            }
        } else if (c === '\n') {
            if (i === 0 || raw.charAt(i - 1) !== '\r') {
                line++;
            }
            column = 0;
        }
        column++;
    }

    if (state === 1) {
        throw jsoncError('Unterminated string', startLine, startColumn);
    }
    if (state === 3) {
        throw jsoncError('Unterminated block comment', startLine, startColumn);
    }

    return out;
}

function jsoncIsWhitespace(c) {
    return c === ' ' || c === '\t' || c === '\r' || c === '\n';
}

function jsoncStripTrailingCommas(chars) {
    var inString = false;
    var escaped = false;
    var i;
    var j;
    var c;
    var previous;

    for (i = 0; i < chars.length; i++) {
        c = chars[i];
        if (inString) {
            if (escaped) {
                escaped = false;
            } else if (c === '\\') {
                escaped = true;
            } else if (c === '"') {
                inString = false;
            }
        } else if (c === '"') {
            inString = true;
        } else if (c === ',') {
            j = i + 1;
            while (j < chars.length && jsoncIsWhitespace(chars[j])) {
                j++;
            }
            if (j < chars.length && (chars[j] === '}' || chars[j] === ']')) {
                previous = i - 1;
                while (previous >= 0 && jsoncIsWhitespace(chars[previous])) {
                    previous--;
                }
                if (previous >= 0 && chars[previous] !== '[' && chars[previous] !== '{' &&
                        chars[previous] !== ',' && chars[previous] !== ':') {
                    chars[i] = ' ';
                }
            }
        }
    }

    return chars.join('');
}

function jsoncValidate(raw) {
    var index = 0;
    var length = raw.length;

    function fail(message, position) {
        var location = jsoncLocation(raw, position);
        throw jsoncError('Invalid JSON: ' + message, location.line, location.column);
    }

    function skipWhitespace() {
        while (index < length && jsoncIsWhitespace(raw.charAt(index))) {
            index++;
        }
    }

    function isDigit(c) {
        return c >= '0' && c <= '9';
    }

    function isHex(c) {
        return (c >= '0' && c <= '9') ||
            (c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F');
    }

    function parseString() {
        var c;
        var escapePosition;
        var j;

        index++;
        while (index < length) {
            c = raw.charAt(index);
            if (c === '"') {
                index++;
                return;
            }
            if (c === '\\') {
                escapePosition = index;
                index++;
                if (index >= length) {
                    fail('Unterminated string escape', escapePosition);
                }
                c = raw.charAt(index);
                if (c === '"' || c === '\\' || c === '/' || c === 'b' ||
                        c === 'f' || c === 'n' || c === 'r' || c === 't') {
                    index++;
                } else if (c === 'u') {
                    for (j = 1; j <= 4; j++) {
                        if (index + j >= length || !isHex(raw.charAt(index + j))) {
                            fail('Invalid Unicode escape', index + j);
                        }
                    }
                    index += 5;
                } else {
                    fail('Invalid string escape', index);
                }
            } else {
                if (c.charCodeAt(0) < 32) {
                    fail('Unescaped control character in string', index);
                }
                index++;
            }
        }
        fail('Unterminated string', length);
    }

    function parseLiteral(word) {
        var j;
        for (j = 0; j < word.length; j++) {
            if (raw.charAt(index + j) !== word.charAt(j)) {
                fail('Invalid literal', index + j);
            }
        }
        index += word.length;
    }

    function parseNumber() {
        if (raw.charAt(index) === '-') {
            index++;
        }
        if (raw.charAt(index) === '0') {
            index++;
            if (isDigit(raw.charAt(index))) {
                fail('Leading zero in number', index);
            }
        } else if (raw.charAt(index) >= '1' && raw.charAt(index) <= '9') {
            while (isDigit(raw.charAt(index))) {
                index++;
            }
        } else {
            fail('Expected digit', index);
        }

        if (raw.charAt(index) === '.') {
            index++;
            if (!isDigit(raw.charAt(index))) {
                fail('Expected digit after decimal point', index);
            }
            while (isDigit(raw.charAt(index))) {
                index++;
            }
        }

        if (raw.charAt(index) === 'e' || raw.charAt(index) === 'E') {
            index++;
            if (raw.charAt(index) === '+' || raw.charAt(index) === '-') {
                index++;
            }
            if (!isDigit(raw.charAt(index))) {
                fail('Expected digit in exponent', index);
            }
            while (isDigit(raw.charAt(index))) {
                index++;
            }
        }
    }

    function parseArray() {
        index++;
        skipWhitespace();
        if (raw.charAt(index) === ']') {
            index++;
            return;
        }

        while (true) {
            parseValue();
            skipWhitespace();
            if (raw.charAt(index) === ']') {
                index++;
                return;
            }
            if (raw.charAt(index) !== ',') {
                fail("Expected ',' or ']'", index);
            }
            index++;
            skipWhitespace();
        }
    }

    function parseObject() {
        index++;
        skipWhitespace();
        if (raw.charAt(index) === '}') {
            index++;
            return;
        }

        while (true) {
            if (raw.charAt(index) !== '"') {
                fail('Expected property name', index);
            }
            parseString();
            skipWhitespace();
            if (raw.charAt(index) !== ':') {
                fail("Expected ':' after property name", index);
            }
            index++;
            parseValue();
            skipWhitespace();
            if (raw.charAt(index) === '}') {
                index++;
                return;
            }
            if (raw.charAt(index) !== ',') {
                fail("Expected ',' or '}'", index);
            }
            index++;
            skipWhitespace();
        }
    }

    function parseValue() {
        var c;
        skipWhitespace();
        if (index >= length) {
            fail('Expected JSON value', index);
        }
        c = raw.charAt(index);
        if (c === '"') {
            parseString();
        } else if (c === '{') {
            parseObject();
        } else if (c === '[') {
            parseArray();
        } else if (c === 't') {
            parseLiteral('true');
        } else if (c === 'f') {
            parseLiteral('false');
        } else if (c === 'n') {
            parseLiteral('null');
        } else if (c === '-' || isDigit(c)) {
            parseNumber();
        } else {
            fail('Expected JSON value', index);
        }
    }

    skipWhitespace();
    parseValue();
    skipWhitespace();
    if (index < length) {
        fail('Unexpected token', index);
    }
}

function jsoncParseError(error, raw) {
    var message = error && error.message ? String(error.message) : String(error);
    var match = /position\s+(\d+)/i.exec(message);
    var location;
    var position;

    if (match) {
        position = parseInt(match[1], 10);
        location = jsoncLocation(raw, position);
    } else if (/unexpected end/i.test(message)) {
        location = jsoncLocation(raw, raw.length);
    } else {
        match = /line\s+(\d+)[^\d]+column\s+(\d+)/i.exec(message);
        if (match) {
            location = { line: parseInt(match[1], 10), column: parseInt(match[2], 10) };
        } else {
            location = { line: 1, column: 1 };
        }
    }

    return jsoncError('Invalid JSON: ' + message, location.line, location.column);
}

function parse(raw) {
    var chars;
    var cleaned;

    if (typeof raw !== 'string') {
        raw = String(raw);
    }
    chars = jsoncStripComments(raw);
    if (chars.length > 0 && chars[0] === '\ufeff') {
        chars[0] = ' ';
    }
    cleaned = jsoncStripTrailingCommas(chars);
    jsoncValidate(cleaned);

    try {
        return JSON.parse(cleaned);
    } catch (error) {
        throw jsoncParseError(error, raw);
    }
}

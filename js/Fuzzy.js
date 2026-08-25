// Fuzzy.js — Omnibox ranking (pure ES5 for Qt V4; no regex, allocation-light).
//
// score(query, text) -> number (lower is better) or null (no match)
//   Case-insensitive. The query is split on whitespace; EVERY term must match
//   `text` (AND semantics) or the whole call returns null. The final score is
//   the sum of each term's best tier score.
//
//   Per-term tiers (all evaluated against the full text; lowest score wins):
//     a. exact       text equals term ......................... base  0
//     b. prefix      text starts with term .................... base 10 + text.length * 0.1
//     c. boundary    every term char lands, in order, on a word
//                    start (word start = index 0, after one of
//                    " _-./", or a lowercase->uppercase camel
//                    transition) .............................. base 25 + firstPos * 0.5 + gaps * 1.5
//     d. substring   contiguous occurrence .................... base 40 + position * 0.5
//     e. subsequence chars appear in order, greedy leftmost ... base 70 + firstPos * 0.3 + gaps * 2
//
//   "firstPos" = position of the first matched char; "gaps" = total number of
//   unmatched chars sitting between consecutive matched chars.
//
//   Bonus: a term of length >= 4 that hits tier (a) or (b) subtracts 5.
//   Per-term scores are floored at 0, so an exact match always scores 0.
//
//   Empty query -> 0. Empty text -> null (unless the query is empty).
//
// normalize(text) -> string
//   Lowercased, runs of whitespace collapsed to a single space, trimmed.
//
// prefixMatch(query, text) -> boolean
//   Cheap prefilter callers MAY run before score(): true when every
//   whitespace-separated term of `query` is a prefix of some
//   whitespace-separated word of `text` (case-insensitive). Any row that
//   fails this check cannot beat a row that passes it on prefix/exact tiers,
//   so callers can skip scoring it. Empty query -> true.

function fuzzyIsSpace(c) {
    return c === ' ' || c === '\t' || c === '\n' || c === '\r';
}

// Split on whitespace without regex; never yields empty terms.
function fuzzySplitTerms(s) {
    var out = [];
    var cur = '';
    var i, c;
    for (i = 0; i < s.length; i++) {
        c = s.charAt(i);
        if (fuzzyIsSpace(c)) {
            if (cur.length > 0) {
                out.push(cur);
                cur = '';
            }
        } else {
            cur += c;
        }
    }
    if (cur.length > 0) {
        out.push(cur);
    }
    return out;
}

// Indices of word-start chars in the ORIGINAL text (case matters for camel
// transitions). Index 0 always qualifies; so does any char following a
// " _-./" separator or a lowercase->uppercase transition.
function fuzzyWordStarts(text) {
    var out = [];
    var i, c, p;
    for (i = 0; i < text.length; i++) {
        if (i === 0) {
            out.push(0);
            continue;
        }
        p = text.charAt(i - 1);
        c = text.charAt(i);
        if (p === ' ' || p === '_' || p === '-' || p === '.' || p === '/') {
            out.push(i);
        } else if (p >= 'a' && p <= 'z' && c >= 'A' && c <= 'Z') {
            out.push(i);
        }
    }
    return out;
}

// Best tier score for one lowercased term against lowerText, or null.
// `starts` is fuzzyWordStarts() of the original text.
function fuzzyScoreTerm(term, lowerText, starts) {
    var tlen = term.length;
    var best = -1;
    var s, pos, k, j, tc, found, fromIdx, firstPos, prevPos, gaps, ok, idx, from;

    // (a) exact
    if (lowerText === term) {
        return 0; // bonus would subtract 5, but scores floor at 0
    }

    // (b) prefix / (d) substring share one indexOf
    pos = lowerText.indexOf(term);
    if (pos === 0) {
        s = 10 + lowerText.length * 0.1;
        if (tlen >= 4) {
            s -= 5;
        }
        best = s;
    }

    // (c) word-boundary alignment: greedy leftmost over word-start positions
    firstPos = -1;
    prevPos = -1;
    gaps = 0;
    ok = true;
    fromIdx = 0;
    for (k = 0; k < tlen && ok; k++) {
        tc = term.charCodeAt(k);
        found = -1;
        for (j = fromIdx; j < starts.length; j++) {
            if (lowerText.charCodeAt(starts[j]) === tc) {
                found = starts[j];
                fromIdx = j + 1;
                break;
            }
        }
        if (found < 0) {
            ok = false;
        } else {
            if (firstPos < 0) {
                firstPos = found;
            }
            if (prevPos >= 0) {
                gaps += found - prevPos - 1;
            }
            prevPos = found;
        }
    }
    if (ok) {
        s = 25 + firstPos * 0.5 + gaps * 1.5;
        if (best < 0 || s < best) {
            best = s;
        }
    }

    // (d) contiguous substring (pos === 0 already handled as prefix)
    if (pos > 0) {
        s = 40 + pos * 0.5;
        if (best < 0 || s < best) {
            best = s;
        }
    }

    // (e) ordered subsequence: greedy leftmost
    firstPos = -1;
    prevPos = -1;
    gaps = 0;
    ok = true;
    from = 0;
    for (k = 0; k < tlen && ok; k++) {
        idx = lowerText.indexOf(term.charAt(k), from);
        if (idx < 0) {
            ok = false;
        } else {
            if (firstPos < 0) {
                firstPos = idx;
            }
            if (prevPos >= 0) {
                gaps += idx - prevPos - 1;
            }
            prevPos = idx;
            from = idx + 1;
        }
    }
    if (ok) {
        s = 70 + firstPos * 0.3 + gaps * 2;
        if (best < 0 || s < best) {
            best = s;
        }
    }

    return best < 0 ? null : best;
}

function score(query, text) {
    if (typeof query !== 'string') {
        query = '';
    }
    if (typeof text !== 'string') {
        text = '';
    }
    var terms = fuzzySplitTerms(query);
    if (terms.length === 0) {
        return 0;
    }
    if (text.length === 0) {
        return null;
    }
    var lowerText = text.toLowerCase();
    var starts = fuzzyWordStarts(text);
    var total = 0;
    var i, t;
    for (i = 0; i < terms.length; i++) {
        t = fuzzyScoreTerm(terms[i].toLowerCase(), lowerText, starts);
        if (t === null) {
            return null;
        }
        total += t;
    }
    return total;
}

function normalize(text) {
    if (typeof text !== 'string') {
        return '';
    }
    text = text.toLowerCase();
    var out = '';
    var prevSpace = true; // also handles leading whitespace
    var i, c;
    for (i = 0; i < text.length; i++) {
        c = text.charAt(i);
        if (fuzzyIsSpace(c)) {
            if (!prevSpace) {
                out += ' ';
                prevSpace = true;
            }
        } else {
            out += c;
            prevSpace = false;
        }
    }
    if (out.length > 0 && out.charAt(out.length - 1) === ' ') {
        out = out.slice(0, out.length - 1);
    }
    return out;
}

function prefixMatch(query, text) {
    if (typeof query !== 'string') {
        query = '';
    }
    if (typeof text !== 'string') {
        text = '';
    }
    var terms = fuzzySplitTerms(query);
    if (terms.length === 0) {
        return true;
    }
    var words = fuzzySplitTerms(text);
    var i, j, t, ok;
    for (i = 0; i < words.length; i++) {
        words[i] = words[i].toLowerCase();
    }
    for (i = 0; i < terms.length; i++) {
        t = terms[i].toLowerCase();
        ok = false;
        for (j = 0; j < words.length; j++) {
            if (words[j].indexOf(t) === 0) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            return false;
        }
    }
    return true;
}

if (typeof module !== "undefined") module.exports = {
    score: score,
    normalize: normalize,
    prefixMatch: prefixMatch
};

// test-fuzzy.js — node test harness for js/Fuzzy.js (loads via new Function).
var fs = require('fs');
var path = require('path');

var src = fs.readFileSync(path.join(__dirname, '..', 'js', 'Fuzzy.js'), 'utf8');
var F = new Function(src + '; return { score: score, normalize: normalize, prefixMatch: prefixMatch };')();

var failures = 0;
function check(name, cond) {
    if (cond) {
        console.log('PASS ' + name);
    } else {
        failures++;
        console.log('FAIL ' + name);
    }
}

// --- basics ---------------------------------------------------------------
check("score('xyz','abc') === null", F.score('xyz', 'abc') === null);
check("score('','anything') === 0", F.score('', 'anything') === 0);
check("score('','') === 0", F.score('', '') === 0);
check("score('a','') === null", F.score('a', '') === null);

// --- strict tier ordering: each text makes exactly one tier reachable ------
var sExact = F.score('fb', 'fb');
var sPrefix = F.score('fb', 'fball');
var sBoundary = F.score('fb', 'foo bar');
var sSubstring = F.score('fb', 'xfb');
var sSubseq = F.score('fb', 'fxb');
check("tier chain non-null", sExact !== null && sPrefix !== null &&
    sBoundary !== null && sSubstring !== null && sSubseq !== null);
check("exact(0) < prefix < boundary < substring < subsequence: " +
    [sExact, sPrefix, sBoundary, sSubstring, sSubseq].join(','),
    sExact < sPrefix && sPrefix < sBoundary && sBoundary < sSubstring && sSubstring < sSubseq);

// 'fire' examples: exact < prefix < substring; subsequence 'fr' worse than prefix 'fi'
check("score('fire','fire') === 0 (exact, bonus floored)", F.score('fire', 'fire') === 0);
check("score('fire','fire') < score('fire','firefox')",
    F.score('fire', 'fire') < F.score('fire', 'firefox'));
check("score('fire','firefox') < score('fire','campfire')",
    F.score('fire', 'firefox') < F.score('fire', 'campfire'));
check("score('fr','firefox') > score('fi','firefox') (subsequence worse than prefix)",
    F.score('fr', 'firefox') > F.score('fi', 'firefox'));

// --- word boundary beats substring/subsequence ------------------------------
var gcChrome = F.score('gc', 'Google Chrome');
var gcLegacies = F.score('gc', 'legacies');
check("score('gc','Google Chrome') non-null", gcChrome !== null);
check("score('gc','legacies') non-null", gcLegacies !== null);
check("boundary('gc','Google Chrome') < subseq('gc','legacies'): " + gcChrome + ' < ' + gcLegacies,
    gcChrome < gcLegacies);
check("camel-hump alignment: score('oM','omarchyMenu') non-null",
    F.score('oM', 'omarchyMenu') !== null);

// --- multi-term AND ----------------------------------------------------------
check("score('web brow','Web Browser') non-null", F.score('web brow', 'Web Browser') !== null);
check("score('web zzz','Web Browser') === null", F.score('web zzz', 'Web Browser') === null);

// --- case-insensitive exact --------------------------------------------------
check("score('FIREFOX','firefox') === 0", F.score('FIREFOX', 'firefox') === 0);
check("score('firefox','FIREFOX') === 0", F.score('firefox', 'FIREFOX') === 0);

// --- normalize ----------------------------------------------------------------
check("normalize('  Hello   World ') === 'hello world'",
    F.normalize('  Hello   World ') === 'hello world');

// --- prefixMatch prefilter ------------------------------------------------------
check("prefixMatch('fi fo','Firefox Focus') === true",
    F.prefixMatch('fi fo', 'Firefox Focus') === true);
check("prefixMatch('fi zz','Firefox Focus') === false",
    F.prefixMatch('fi zz', 'Firefox Focus') === false);

// --- sanity ranking ---------------------------------------------------------------
check("score('om','Omarchy') < score('om','Documents'): " +
    F.score('om', 'Omarchy') + ' < ' + F.score('om', 'Documents'),
    F.score('om', 'Omarchy') < F.score('om', 'Documents'));

console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)');
process.exit(failures === 0 ? 0 : 1);

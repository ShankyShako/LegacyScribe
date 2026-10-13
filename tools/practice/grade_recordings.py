# /// script
# dependencies = ["cmudict"]
# ///
"""Grade read-aloud recordings across engines, setting aside what wasn't a hearing error.

Run lsbench over the calibration folder first, once per engine, writing <stem>-calibration.json into the
bench folder (see docs/bench-results.md, "Read-aloud grading"). Then:

    python3 grade_recordings.py            (needs `pip install cmudict`)

Each difference from the script is one of: formatting (dropped: same pronunciation, "harbour"), a new word
(the script word isn't in the CMU dictionary: jargon no engine can spell), "you said" (3+ of the 4 engines
heard the same other word), sound-alike (close phonemes, engines disagree), or an engine error. The app's
`PracticeGrade` uses the same idea with two engine families instead of the CMU dictionary.
"""
# Grade practice recordings: how much of each line each engine heard, after setting aside
# formatting differences and words the speaker most likely said differently.
import json, re, sys, os, collections
import cmudict
PRON = cmudict.dict()
BENCH = os.path.expanduser("~/Library/Application Support/LegacyScribe/bench")
ENGINES = {"cohere": "cohere-4bit", "ultra": "parakeet-ultra", "v3": "parakeet-v3", "v2": "parakeet-v2"}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
def numword(n):
    if n < 20: return ONES[n]
    if n < 100: return TENS[n//10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000: return ONES[n//100] + " hundred" + ("" if n % 100 == 0 else " " + numword(n % 100))
    return str(n)
def norm(text):
    t = text.lower().replace("’", "'").replace("-", " ").replace("%", " percent")
    t = re.sub(r"(\d)\.(\d)", r"\1 point \2", t)
    t = re.sub(r"\d+", lambda m: " " + numword(int(m.group())) + " ", t)
    t = re.sub(r"[^a-z0-9' ]", " ", t)
    words = [w.strip("'") for w in t.split()]
    return [w for w in words if w and w not in ("uh", "um", "er", "hmm")]
def align(ref, hyp):
    n, m = len(ref), len(hyp)
    D = [[0]*(m+1) for _ in range(n+1)]
    for i in range(n+1): D[i][0] = i
    for j in range(m+1): D[0][j] = j
    for i in range(1, n+1):
        for j in range(1, m+1):
            D[i][j] = min(D[i-1][j-1] + (ref[i-1] != hyp[j-1]), D[i-1][j] + 1, D[i][j-1] + 1)
    ops, i, j = [], n, m
    while i or j:
        if i and j and D[i][j] == D[i-1][j-1] + (ref[i-1] != hyp[j-1]):
            ops.append((i-1, ref[i-1], hyp[j-1])); i -= 1; j -= 1
        elif i and D[i][j] == D[i-1][j] + 1:
            ops.append((i-1, ref[i-1], None)); i -= 1
        else:
            ops.append((i, None, hyp[j-1])); j -= 1
    return ops[::-1]
def merge_compounds(ops):
    # "swift ui" for "swiftui", "pull request" vs "pullrequest": join runs that spell the same letters.
    out, k = [], 0
    while k < len(ops):
        done = False
        for span in (2, 3):
            seg = ops[k:k+span]
            if len(seg) < span: break
            r = "".join(o[1] or "" for o in seg); h = "".join(o[2] or "" for o in seg)
            if r and r == h and any(o[1] != o[2] for o in seg):
                out.append((seg[0][0], r, h)); k += span; done = True; break
        if not done: out.append(ops[k]); k += 1
    return out
def phones(w):
    p = PRON.get(w)
    return [re.sub(r"\d", "", x) for x in p[0]] if p else None
def edit(a, b):
    prev = list(range(len(b)+1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1): cur.append(min(prev[j-1] + (x != y), prev[j] + 1, cur[j-1] + 1))
        prev = cur
    return prev[-1]
def sound_alike(r, h):
    pr, ph = phones(r), phones(h)
    if not pr or not ph: return False
    return edit(pr, ph) <= max(1, len(pr) // 4)

data = {}
for key, stem in ENGINES.items():
    for fx in json.load(open(f"{BENCH}/{stem}-calibration.json"))["fixtures"]:
        data.setdefault(fx["fixture"], {"ref": fx["reference"]})[key] = fx["hypothesis"]

totals = collections.Counter(); per_engine = {k: collections.Counter() for k in ENGINES}
lines_out = []
for fid, row in sorted(data.items()):
    ref = norm(row["ref"])
    errs = {}
    for k in ENGINES:
        errs[k] = [o for o in merge_compounds(align(ref, norm(row[k]))) if o[1] != o[2]]
    # An error at the same reference word with the same heard word from 3+ engines: the audio carries it.
    sig = collections.Counter((o[0], o[1], o[2]) for k in ENGINES for o in errs[k])
    report = {"id": fid, "ref": row["ref"], "words": len(ref), "engines": {}}
    for k in ENGINES:
        engine_err, said, alike, newword = [], [], [], []
        for o in errs[k]:
            if o[1] and o[2] and phones(o[1]) and phones(o[1]) == phones(o[2]): continue  # harbor/harbour
            if o[1] and phones(o[1]) is None: newword.append(o)  # jargon the engine can't know
            elif sig[(o[0], o[1], o[2])] >= 3: said.append(o)
            elif o[1] and o[2] and sound_alike(o[1], o[2]): alike.append(o)
            else: engine_err.append(o)
        raw = len(engine_err) + len(said) + len(alike) + len(newword); n = max(1, len(ref))
        report["engines"][k] = {"hyp": row[k], "raw": raw, "engine": engine_err, "said": said, "alike": alike, "new": newword,
            "heard": 1 - (len(engine_err) + len(alike)) / n, "heard_strict": 1 - (len(engine_err) + len(alike)) / n, "literal": 1 - raw / n}
        c = per_engine[k]; c["words"] += len(ref); c["raw"] += raw; c["engine"] += len(engine_err); c["said"] += len(said); c["alike"] += len(alike); c["new"] += len(newword)
        c["pass95"] += report["engines"][k]["heard"] >= 0.95; c["pass95_literal"] += report["engines"][k]["literal"] >= 0.95; c["lines"] += 1
    lines_out.append(report)
json.dump(lines_out, open("/tmp/grade/report.json", "w"), indent=1)
print(f"{'engine':8} {'words':>5} {'literal WER':>11} {'engine WER':>10} {'you said':>8} {'sound-alike':>11} {'new word':>8} {'lines ≥95% (literal)':>20} {'lines ≥95% (graded)':>19}")
for k, c in per_engine.items():
    print(f"{k:8} {c['words']:5} {c['raw']/c['words']:11.1%} {c['engine']/c['words']:10.1%} {c['said']:8} {c['alike']:11} {c['new']:8} {c['pass95_literal']:>13}/{c['lines']} {c['pass95']:>13}/{c['lines']}")
print()
for r in lines_out:
    e = r["engines"]
    if all(not e[k]["raw"] for k in ENGINES): continue
    print(f"[{r['id']}] {r['ref']}")
    for k in ENGINES:
        x = e[k]
        if not x["raw"]: continue
        fmt = lambda os: ", ".join(f"{o[1] or '∅'}→{o[2] or '∅'}" for o in os)
        print(f"   {k:7} heard {x['heard']:.0%} | engine: {fmt(x['engine']) or '-'} | you said: {fmt(x['said']) or '-'} | sound-alike: {fmt(x['alike']) or '-'} | new word: {fmt(x['new']) or '-'}")

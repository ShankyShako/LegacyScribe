"""Score lsbench rewrite reports against the Clean text that was actually pasted (gpt-oss-120b).

usage: score.py eval.jsonl report.json [report.json ...] [--md side-by-side.md]

Per model: word error rate against the reference with case and punctuation ignored (did it keep
the same words?), the same with case and punctuation kept (did it format the same way?), answers
the app would refuse, empty answers, and median seconds per dictation.
"""
import json, re, statistics, sys

def words(text, keep_format):
    if keep_format:
        return re.findall(r"[\w'’]+|[^\w\s]", text)
    return re.findall(r"[\w'’]+", text.lower().replace("’", "'"))

def distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def error_rate(outputs, references, keep_format):
    errors = sum(distance(words(o, keep_format), words(r, keep_format)) for o, r in zip(outputs, references))
    total = sum(len(words(r, keep_format)) for r in references)
    return 100 * errors / max(total, 1)

args = sys.argv[1:]
md = None
if "--md" in args:
    i = args.index("--md"); md = args[i + 1]; del args[i:i + 2]
evals = [json.loads(l) for l in open(args[0])]
refs = [e["reference"] for e in evals]
reports = [json.load(open(p)) for p in args[1:]]

print(f"{'model':40} {'WER':>6} {'fmt':>6} {'fell back':>8} {'empty':>6} {'median s':>9} {'peak MB':>8}")
for rep in reports:
    res = rep["results"]
    assert len(res) == len(evals), f"{rep['model']}: {len(res)} results for {len(evals)} samples"
    # What the app would paste: a cut-off or refused answer falls back to the heard text.
    outs = [e["transcript"] if r.get("truncated") or r.get("rejected") else r["output"] for e, r in zip(evals, res)]
    print(f"{rep['model'][:40]:40} {error_rate(outs, refs, False):6.1f} {error_rate(outs, refs, True):6.1f} "
          f"{sum(bool(r.get('rejected') or r.get('truncated')) for r in res):8d} {sum(not o.strip() for o in outs):6d} "
          f"{statistics.median(r['seconds'] for r in res):9.2f} {rep['peakFootprintMB']:8.0f}")

if md:
    with open(md, "w") as f:
        for k, e in enumerate(evals):
            f.write(f"## {k + 1}\n\n**Heard:** {e['transcript']}\n\n**gpt-oss (pasted):** {e['reference']}\n\n")
            for rep in reports:
                r = rep["results"][k]
                flag = f" *(refused: {r.get('rejected')})*" if r.get("rejected") else ""
                f.write(f"**{rep['model']}** ({r['seconds']:.2f} s){flag}: {r['output']}\n\n")

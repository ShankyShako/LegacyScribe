"""Unblind the judge's scores: per system, mean of each criterion, mean rank, wins, and serious faults.

usage: unblind.py packet-dir/scores.json KEY_FILE eval.jsonl [name=report.json ...]

The optional reports add a structure count: for dictations of 80+ heard words, the share of
answers that came out as one paragraph (a "blob").
"""
import json, statistics, sys
from collections import defaultdict

scores = json.load(open(sys.argv[1]))
key = json.load(open(sys.argv[2]))
evals = [json.loads(l) for l in open(sys.argv[3])]
long_ids = {k for k, e in enumerate(evals) if len(e["transcript"].split()) >= 80}

table = defaultdict(lambda: defaultdict(list))
notes = defaultdict(list)
for entry in scores:
    k = entry["dictation"] - 1
    for letter, s in entry["scores"].items():
        name = key[k][letter]
        for c in ("faithful", "clean", "professional", "structure", "rank"):
            table[name][c].append(s[c])
        if k in long_ids:
            table[name]["rank_long"].append(s["rank"])
        if s.get("note"):
            notes[name].append(f"{k + 1}: {s['note']}")

print(f"{'system':10} {'faithful':>8} {'clean':>6} {'prof':>6} {'struct':>6} {'rank':>5} {'rank 80+w':>9} {'wins':>5} {'faults':>6}")
for name in sorted(table, key=lambda n: statistics.mean(table[n]["rank"])):
    t = table[name]
    print(f"{name:10} {statistics.mean(t['faithful']):8.2f} {statistics.mean(t['clean']):6.2f} {statistics.mean(t['professional']):6.2f} "
          f"{statistics.mean(t['structure']):6.2f} {statistics.mean(t['rank']):5.2f} {statistics.mean(t['rank_long']):9.2f} "
          f"{t['rank'].count(1):5d} {len(notes[name]):6d}")
print(f"\n{len(long_ids)} dictations of 80+ words")
for arg in sys.argv[4:]:
    name, path = arg.split("=", 1)
    outs = [e["reference"] for e in evals] if path == "reference" else [r["output"] for r in json.load(open(path))["results"]]
    blobs = sum(1 for k in long_ids if "\n\n" not in outs[k].strip())
    print(f"{name}: {blobs}/{len(long_ids)} long answers in one paragraph")
print()
for name in notes:
    print(f"## {name}"); [print("  " + n) for n in notes[name]]

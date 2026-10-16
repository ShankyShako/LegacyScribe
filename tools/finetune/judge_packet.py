"""Blind judging packet: each dictation's heard text plus every system's output under shuffled letters.

usage: judge_packet.py eval.jsonl OUT_DIR KEY_FILE [--also-heard stt-report.json] name=report.json [name=report.json ...]
       (name=reference uses eval.jsonl's pasted gpt-oss text)

--also-heard adds a second engine's transcript of each recording (an lsbench speech-to-text report with
fixtures named by dictation ID), for comparing systems that started from different heard texts. The
packet doesn't say which system started from which.

Writes OUT_DIR/packet.md for the judge and KEY_FILE (letter → system per dictation), which the
judge must not see. Keep KEY_FILE outside OUT_DIR.
"""
import json, os, random, sys

evals = [json.loads(l) for l in open(sys.argv[1])]
out_dir, key_file = sys.argv[2], sys.argv[3]
args = sys.argv[4:]
also = {}
if "--also-heard" in args:
    i = args.index("--also-heard")
    also = {f["fixture"]: f["hypothesis"] for f in json.load(open(args[i + 1]))["fixtures"]}
    del args[i:i + 2]
systems = {}
for arg in args:
    name, path = arg.split("=", 1)
    if path == "reference":
        systems[name] = [e["reference"] for e in evals]
    else:
        # What the app would paste: a cut-off or refused answer falls back to the heard text.
        results = json.load(open(path))["results"]
        systems[name] = [e["transcript"] if r.get("truncated") or r.get("rejected") else r["output"] for e, r in zip(evals, results)]

rng = random.Random(1016)
key = []
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "packet.md"), "w") as f:
    for k, e in enumerate(evals):
        names = list(systems)
        rng.shuffle(names)
        letters = {chr(65 + i): n for i, n in enumerate(names)}
        key.append(letters)
        if also:
            f.write(f"## Dictation {k + 1} ({len(e['transcript'].split())} words heard)\n\n### Heard by engine 1\n\n{e['transcript']}\n\n"
                    f"### Heard by engine 2\n\n{also.get(e['id'], '').strip() or '(nothing)'}\n\n")
        else:
            f.write(f"## Dictation {k + 1} ({len(e['transcript'].split())} words heard)\n\n### Heard\n\n{e['transcript']}\n\n")
        for letter, name in letters.items():
            f.write(f"### {letter}\n\n{systems[name][k].strip() or '(empty)'}\n\n")
json.dump(key, open(key_file, "w"), indent=1)
print(f"{len(evals)} dictations × {len(systems)} systems")

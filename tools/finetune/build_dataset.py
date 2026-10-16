"""Build an mlx_lm LoRA dataset (chat format) from the training pool.

usage: build_dataset.py pool.jsonl OUT_DIR [--targets report.json] [--also-inputs stt-report.json]

Targets are the pool's references (the gpt-oss-120b Clean text that was pasted) unless --targets
names an lsbench rewrite report over the same pool, in order (e.g. the 4B's rewrites). The same
30 dictations always go to valid.jsonl so runs are comparable. The assistant turn starts with
Qwen3's empty think block, the prefix it sees at inference with enable_thinking off.
--also-inputs names an lsbench speech-to-text report (fixtures named by dictation ID, e.g. Apple Speech
over the same recordings): each dictation it covers gets a second example with that transcript as the
input and the same target, in the same split.
"""
import json, os, random, sys

SYSTEM = "Rewrite this dictation as clean written text."
VALID = 30

args = sys.argv[1:]
targets = None
if "--targets" in args:
    i = args.index("--targets"); targets = args[i + 1]; del args[i:i + 2]
also = {}
if "--also-inputs" in args:
    i = args.index("--also-inputs")
    also = {f["fixture"]: f["hypothesis"] for f in json.load(open(args[i + 1]))["fixtures"]}
    del args[i:i + 2]
pool = [json.loads(l) for l in open(args[0])]
out = args[1]

if targets:
    results = json.load(open(targets))["results"]
    assert len(results) == len(pool), "report and pool differ in length"
    answers = [None if r.get("rejected") or r.get("truncated") else r["output"] for r in results]
else:
    answers = [p["reference"] for p in pool]

valid_ids = set(p["id"] for p in random.Random(16).sample(pool, VALID))
os.makedirs(out, exist_ok=True)
counts = {"train": 0, "valid": 0, "skipped": 0}
with open(os.path.join(out, "train.jsonl"), "w") as t, open(os.path.join(out, "valid.jsonl"), "w") as v:
    for p, answer in zip(pool, answers):
        if not answer or not answer.strip():
            counts["skipped"] += 1
            continue
        split = "valid" if p["id"] in valid_ids else "train"
        second = also.get(p["id"], "").strip()
        inputs = [p["transcript"]] + ([second] if second else [])
        for heard in inputs:
            line = json.dumps({"messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": heard},
                {"role": "assistant", "content": "<think>\n\n</think>\n\n" + answer.strip()},
            ]})
            (v if split == "valid" else t).write(line + "\n")
            counts[split] += 1
print(counts)

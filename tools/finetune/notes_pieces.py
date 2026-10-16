"""Cut Notes transcripts into dictation-sized pieces for rewrite training (inputs only; labels come later).

usage: notes_pieces.py OUT.jsonl [--pool pool.jsonl]

Each session's transcript.jsonl (one ≤30 s chunk per line) is joined and recut at sentence ends,
so no piece starts or stops mid-sentence the way the raw chunks do. Piece lengths are drawn from
the pool's heard-word lengths (so they look like real dictations), at least 8 words. Gap lines
(failed chunks) and transcripts flagged as loops never reach the file: the transcript holds only
committed text. Writes lsbench samples ({"mode": "clean", "transcript", "reference": "", "id"}).
Notes text never leaves this Mac: label it with label_local.py, never a cloud endpoint.
"""
import glob, json, os, random, re, sys

ROOT = os.path.expanduser(os.environ.get("LEGACYSCRIBE_DATA_ROOT", "~/Library/Application Support/LegacyScribe"))
args = sys.argv[1:]
pool = os.path.join(ROOT, "finetune", "pool.jsonl")
if "--pool" in args:
    i = args.index("--pool"); pool = args[i + 1]; del args[i:i + 2]
lengths = [n for n in (len(json.loads(l)["transcript"].split()) for l in open(pool)) if n >= 8]
rng = random.Random(1016)

pieces = []
for session in sorted(glob.glob(os.path.join(ROOT, "Notes", "*", "transcript.jsonl"))):
    name = os.path.basename(os.path.dirname(session))
    lines = sorted((json.loads(l) for l in open(session)), key=lambda d: d["chunk"])
    text = " ".join(d["text"].strip() for d in lines if d["text"].strip())
    sentences = re.split(r"(?<=[.?!])\s+", text)
    target, current = rng.choice(lengths), []
    for s in sentences:
        current.append(s)
        if len(" ".join(current).split()) >= target:
            pieces.append({"mode": "clean", "transcript": " ".join(current), "reference": "", "id": f"{name}-{len(pieces)}"})
            target, current = rng.choice(lengths), []
    if len(" ".join(current).split()) >= 8:
        pieces.append({"mode": "clean", "transcript": " ".join(current), "reference": "", "id": f"{name}-{len(pieces)}"})

with open(args[0], "w") as f:
    for p in pieces:
        f.write(json.dumps(p) + "\n")
words = sorted(len(p["transcript"].split()) for p in pieces)
print(f"{len(pieces)} pieces, {sum(words)} words, median {words[len(words) // 2]}, max {words[-1]}")

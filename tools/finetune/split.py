"""Split the Clean dictations in History into a held-out eval set and a training pool.

Writes <data root>/finetune/{eval,pool}.jsonl. Each line: id, transcript (rawText),
reference (the Clean text that was pasted), sent (what the user sent, if a sent edit
exists). The user's text never goes into the repo.
"""
import json, os, random, sqlite3, sys

ROOT = os.path.expanduser(os.environ.get("LEGACYSCRIBE_DATA_ROOT", "~/Library/Application Support/LegacyScribe"))
OUT = os.path.join(ROOT, "finetune")
EVAL_SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 40

db = sqlite3.connect(os.path.join(ROOT, "scribe.sqlite"))
rows = db.execute("""
    select d.id, d.rawText, d.text, c.sent, c.pasted
    from dictations d left join corrections c on c.dictationID = d.id
    where d.rewriteMode = 'clean' and d.rawText is not null and d.rawText != ''
      and d.rewrittenBy like '%gpt-oss%' and d.failure is null
    order by d.timestamp
""").fetchall()

seen, items = set(), []
for id, raw, text, sent, pasted in rows:
    if id in seen:
        continue
    seen.add(id)
    item = {"id": id, "transcript": raw, "reference": text}
    if sent and pasted and sent != pasted:
        item["sent"] = sent
    items.append(item)

# Stratify by length so the eval set has short, medium and long dictations.
items.sort(key=lambda i: len(i["transcript"]))
rng = random.Random(15)
n = len(items)
eval_ids = set()
for k in range(EVAL_SIZE):
    lo, hi = k * n // EVAL_SIZE, (k + 1) * n // EVAL_SIZE
    eval_ids.add(items[rng.randrange(lo, hi)]["id"])

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "eval.jsonl"), "w") as e, open(os.path.join(OUT, "pool.jsonl"), "w") as p:
    for item in items:
        (e if item["id"] in eval_ids else p).write(json.dumps(item) + "\n")
print(f"{len(items)} Clean dictations: {len(eval_ids)} eval, {len(items) - len(eval_ids)} pool, {sum('sent' in i for i in items)} with a sent edit")

"""Add the 27B-labelled Notes pieces to an existing LoRA dataset (train only).

usage: build_notes_mix.py BASE_DIR pieces.jsonl labels.json OUT_DIR [--min-kept N]

BASE_DIR is a build_dataset.py folder (e.g. data-para): its train.jsonl and valid.jsonl are copied
unchanged, so the 30 validation dictations stay the same and val loss stays comparable. Each Notes
piece from pieces.jsonl (notes_pieces.py; its "transcript" is the model's input) is paired with the
same position in labels.json (label_local.py report, e.g. qwen3.6:27b) and appended to train.jsonl
with build_dataset.py's system prompt and empty-think assistant prefix. A piece is dropped when it
has no label yet, the label is empty or was cut off (truncated), or the label has fewer than 0.6x or
more than 1.4x the piece's words (a summary or an expansion, not a cleanup).

Prints the counts and writes them to OUT_DIR/mix-counts.json. Exit status 3 when fewer than
--min-kept pieces survive (the dataset is still written). Notes text never leaves this Mac.
"""
import json, os, shutil, sys

SYSTEM = "Rewrite this dictation as clean written text."   # as build_dataset.py
LOW, HIGH = 0.6, 1.4

args = sys.argv[1:]
min_kept = 0
if "--min-kept" in args:
    i = args.index("--min-kept"); min_kept = int(args[i + 1]); del args[i:i + 2]
base, pieces_path, labels_path, out = args
pieces = [json.loads(l) for l in open(pieces_path)]
results = json.load(open(labels_path))["results"] if os.path.exists(labels_path) else []

os.makedirs(out, exist_ok=True)
for name in ("train.jsonl", "valid.jsonl"):
    shutil.copyfile(os.path.join(base, name), os.path.join(out, name))
base_train = sum(1 for _ in open(os.path.join(base, "train.jsonl")))
valid = sum(1 for _ in open(os.path.join(base, "valid.jsonl")))

counts = {"pieces": len(pieces), "labelled": len(results), "kept": 0, "no label yet": 0, "empty": 0,
          "truncated": 0, "too short (<0.6x)": 0, "too long (>1.4x)": 0}
with open(os.path.join(out, "train.jsonl"), "a") as train:
    for k, piece in enumerate(pieces):
        if k >= len(results):
            counts["no label yet"] += 1
            continue
        r = results[k]
        answer = (r.get("output") or "").strip()
        heard = piece["transcript"].strip()
        if r.get("truncated"):
            counts["truncated"] += 1
        elif not answer or not heard:
            counts["empty"] += 1
        else:
            ratio = len(answer.split()) / len(heard.split())
            if ratio < LOW:
                counts["too short (<0.6x)"] += 1
            elif ratio > HIGH:
                counts["too long (>1.4x)"] += 1
            else:
                train.write(json.dumps({"messages": [
                    {"role": "system", "content": SYSTEM},
                    {"role": "user", "content": heard},
                    {"role": "assistant", "content": "<think>\n\n</think>\n\n" + answer},
                ]}) + "\n")
                counts["kept"] += 1

counts.update({"base_train": base_train, "train": base_train + counts["kept"], "valid": valid})
json.dump(counts, open(os.path.join(out, "mix-counts.json"), "w"), indent=1)
dropped = ", ".join(f"{counts[k]} {k}" for k in
                    ("no label yet", "empty", "truncated", "too short (<0.6x)", "too long (>1.4x)") if counts[k])
print(f"{counts['kept']} of {len(pieces)} Notes pieces kept ({counts['labelled']} labelled); dropped: {dropped or 'none'}")
print(f"train {counts['train']} ({base_train} + {counts['kept']}), valid {valid}")
if counts["kept"] < min_kept:
    print(f"fewer than {min_kept} pieces kept", file=sys.stderr)
    sys.exit(3)

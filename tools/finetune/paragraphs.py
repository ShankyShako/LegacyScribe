"""Add paragraph breaks to long training targets without changing a word, using a local Ollama model.

usage: paragraphs.py pool.jsonl OUT.jsonl [--model qwen3.6:27b] [--min-words 80]

Each pool reference of --min-words or more that is still one paragraph goes to the model with the
instruction to insert blank lines where the topic shifts. The answer is kept only if its words are
exactly the reference's words in order (whitespace aside); otherwise the reference stays as it was.
Runs on this Mac only (Ollama at localhost), like everything else that touches the user's text.
"""
import json, sys, urllib.request

args = sys.argv[1:]
model, min_words = "qwen3.6:27b", 80
if "--model" in args:
    i = args.index("--model"); model = args[i + 1]; del args[i:i + 2]
if "--min-words" in args:
    i = args.index("--min-words"); min_words = int(args[i + 1]); del args[i:i + 2]

TASK = ("Split the text below into paragraphs where the topic shifts, separated by a blank line: usually 2 to 4 "
        "paragraphs. Do not change, add or remove a single word or punctuation mark. Output only the text.")

def ask(text):
    body = {"model": model, "stream": False, "think": False, "options": {"temperature": 0, "num_ctx": 8192},
            "messages": [{"role": "system", "content": TASK}, {"role": "user", "content": text}]}
    req = urllib.request.Request("http://localhost:11434/api/chat", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=300))["message"]["content"].strip()

pool = [json.loads(l) for l in open(args[0])]
counts = {"split": 0, "rejected": 0, "unchanged": 0}
with open(args[1], "w") as out:
    for p in pool:
        ref = p["reference"].strip()
        if len(ref.split()) >= min_words and "\n\n" not in ref:
            answer = ask(ref)
            if answer.split() == ref.split() and "\n\n" in answer:
                p = dict(p, reference="\n\n".join(par.strip() for par in answer.split("\n\n") if par.strip()))
                counts["split"] += 1
            else:
                counts["rejected"] += 1
        else:
            counts["unchanged"] += 1
        out.write(json.dumps(p) + "\n")
        out.flush()
print(counts)

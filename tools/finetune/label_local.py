"""Rewrite dumped lsbench messages with a local Ollama model (this Mac only), as an lsbench-style report.

usage: label_local.py messages.jsonl OUT.json [--model qwen3.6:27b]

messages.jsonl is `lsbench rewrite --messages` output (one chat per line). OUT.json has lsbench's
report shape ({"model", "peakFootprintMB", "results": [{"output", "seconds", "truncated"}]}), so
score.py, judge_packet.py and build_dataset.py --targets read it. Ollama's native /api/chat with
think off and a fixed num_ctx (changing it between calls reloads the model). Progress is written
after every answer, and a rerun picks up where the last one stopped.
"""
import json, os, sys, time, urllib.request

args = sys.argv[1:]
model = "qwen3.6:27b"
if "--model" in args:
    i = args.index("--model"); model = args[i + 1]; del args[i:i + 2]
chats = [json.loads(l) for l in open(args[0])]
out_path = args[1]

results = json.load(open(out_path))["results"] if os.path.exists(out_path) else []
for messages in chats[len(results):]:
    words = len(messages[-1]["content"].split())
    body = {"model": model, "messages": messages, "stream": False, "think": False,
            "options": {"temperature": 0.2, "num_ctx": 16384, "num_predict": int(2.5 * words) + 256}}
    req = urllib.request.Request("http://localhost:11434/api/chat", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=600))
    results.append({"output": r["message"]["content"].strip(), "seconds": time.time() - t,
                    "truncated": r.get("done_reason") == "length"})
    json.dump({"model": model, "peakFootprintMB": 0, "results": results}, open(out_path, "w"), indent=1)
    print(f"{len(results)}/{len(chats)} {results[-1]['seconds']:.1f} s", flush=True)

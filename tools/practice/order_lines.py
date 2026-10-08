#!/usr/bin/env python3
# /// script
# dependencies = ["cmudict"]
# ///
"""Orders candidate practice sentences so that stopping early still gives good training data.

Reads JSON lines {"group": "general"|"detail", "text": "..."} and writes the app's
Hex/Resources/Data/practice_lines.json:

1. "sounds": general sentences picked greedily until every English phoneme (CMU, 39) occurs twice.
2. "pairs":  the remaining general sentences, greedily by new phoneme pairs (diphones) per word,
            the selection rule CMU Arctic used.
3. "detail": the detail sentences (jargon, code talk, numbers), greedily by new diphones plus
            new out-of-dictionary words (technical terms the recognizer is least likely to know).
4. "extra":  general sentences that add no new diphone; more samples of known sounds.

Each line carries cumulative coverage so the app can say how much a stopped session covered.
Usage: python3 order_lines.py candidates.jsonl > practice_lines.json   (needs `pip install cmudict`)
"""
import hashlib
import json
import math
import re
import sys

import cmudict

PRON = cmudict.dict()
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n):
    if n < 20:
        return [ONES[n]]
    if n < 100:
        return [TENS[n // 10]] + ([ONES[n % 10]] if n % 10 else [])
    if n < 1000:
        return [ONES[n // 100], "hundred"] + (number_words(n % 100) if n % 100 else [])
    if n < 100000:
        return number_words(n // 1000) + ["thousand"] + (number_words(n % 1000) if n % 1000 else [])
    return [ONES[int(d)] for d in str(n)]


def spoken_words(text):
    """Rough spoken form: digits become words, a dot between digits is "point" (2.4.1), and a time's
    colon is a pause (3:15 → three fifteen)."""
    text = re.sub(r"(?<=\d)\.(?=\d)", " point ", text)
    words = []
    for token in re.findall(r"[A-Za-z']+|\d+", text):
        if token.isdigit():
            words += number_words(int(token))
        else:
            words.append(token.lower().strip("'"))
    return [w for w in words if w]


def phonemes(text):
    """Phoneme sequence (stress removed) and the words the dictionary doesn't know."""
    seq, unknown = [], set()
    for word in spoken_words(text):
        prons = PRON.get(word)
        if not prons:
            unknown.add(word)
            seq.append("|")  # A gap: no pair across an unknown word.
            continue
        seq += [re.sub(r"\d", "", p) for p in prons[0]]
    return seq, unknown


def diphones(seq):
    return {(a, b) for a, b in zip(seq, seq[1:]) if "|" not in (a, b)}


ALL_PHONEMES = {re.sub(r"\d", "", p) for prons in PRON.values() for pron in prons for p in pron}


def main():
    rows = []
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line.startswith("{"):
            continue
        item = json.loads(line)
        text = item["text"].strip()
        if not text or any(text.lower() == r["text"].lower() for r in rows):
            continue
        seq, unknown = phonemes(text)
        rows.append({
            "group": item.get("group", "general"),
            "text": text,
            "words": max(1, len(text.split())),
            "counts": {p: seq.count(p) for p in set(seq) if p != "|"},
            "pairs": diphones(seq),
            "unknown": unknown,
        })

    all_pairs = set().union(*(r["pairs"] for r in rows))
    have = {p: 0 for p in ALL_PHONEMES}
    covered_pairs, seen_unknown, ordered = set(), set(), []

    def take(row, stage):
        nonlocal covered_pairs
        rows.remove(row)
        for p, c in row["counts"].items():
            have[p] = have.get(p, 0) + c
        covered_pairs |= row["pairs"]
        seen_unknown.update(row["unknown"])
        ordered.append({
            # Stable across rebuilds, so reordering never breaks recorded progress.
            "id": "l" + hashlib.sha1(row["text"].encode()).hexdigest()[:10],
            "text": row["text"],
            "stage": stage,
            "soundsCovered": sum(1 for p in ALL_PHONEMES if have[p] > 0),
            "pairsCoveredPercent": round(100 * len(covered_pairs) / len(all_pairs)),
        })

    general = lambda: [r for r in rows if r["group"] == "general"]

    # 1. Every phoneme twice, in as few short lines as possible.
    def deficit(r):
        return sum(min(c, max(0, 2 - have[p])) for p, c in r["counts"].items())

    while any(have[p] < 2 for p in ALL_PHONEMES) and general():
        best = max(general(), key=lambda r: (deficit(r) * 10 + len(r["pairs"] - covered_pairs)) / math.sqrt(r["words"]))
        if deficit(best) == 0:
            break  # No general line has the sounds still short; the detail lines may.
        take(best, "sounds")
    short = sorted(p for p in ALL_PHONEMES if have[p] < 2)
    if short:
        print(f"after the sounds stage these occur fewer than twice: {short}", file=sys.stderr)

    # 2. General lines by new diphones per word, while they add any.
    while general():
        best = max(general(), key=lambda r: (len(r["pairs"] - covered_pairs) / r["words"], -r["words"]))
        if not best["pairs"] - covered_pairs:
            break
        take(best, "pairs")

    # 3. Detail lines: new diphones plus new unknown (technical) words.
    detail = lambda: [r for r in rows if r["group"] == "detail"]
    while detail():
        take(max(detail(), key=lambda r: (len(r["pairs"] - covered_pairs) + 3 * len(r["unknown"] - seen_unknown)) / math.sqrt(r["words"])), "detail")

    # 4. General lines that add no new pair: more recordings of known sounds, for whoever reads on.
    while rows:
        take(rows[0], "extra")

    missing = sorted(p for p in ALL_PHONEMES if have[p] == 0)
    print(json.dumps({"version": 1, "lines": ordered}, indent=1, ensure_ascii=False))
    stages = {s: sum(1 for l in ordered if l["stage"] == s) for s in ("sounds", "pairs", "detail", "extra")}
    print(f"{len(ordered)} lines {stages}; phonemes missing: {missing or 'none'}; {len(all_pairs)} diphones", file=sys.stderr)


if __name__ == "__main__":
    main()

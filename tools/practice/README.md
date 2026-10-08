# Practice script

`Hex/Resources/Data/practice_lines.json` is the read-aloud script in Settings › Practice. Its order is the point: a session can stop anywhere and still have recorded the most useful lines for the time spent.

| Stage | Lines | Rule |
|---|---|---|
| `sounds` | first ~9 | every English phoneme (CMU, 39) at least twice, fewest words |
| `pairs` | next ~110 | most new phoneme pairs (diphones) per word, the rule CMU Arctic used |
| `detail` | next ~125 | the user's own dictation: jargon, spoken code, numbers, fillers; new diphones + new out-of-dictionary words |
| `extra` | rest | general lines that add no new pair: more samples of known sounds |

## Where the sentences came from (2026-10-08)

Generated through OmniRoute with `delegate`, then filtered and ordered here:
- `request-general.md` → `head` (answered by poolside/laguna): the 141 general lines. Its detail lines were too short and generic and were dropped.
- `request-detail.md` → `wp-heavy` and `wp-code` (both claude-sonnet-4.5): the detail lines, merged, without copies of the prompt's examples or repeated three-word openings.
- `request-rare-sounds.md` → `wp-fast` (gemini-3.1-flash-lite): 14 lines for "oy" and "zh", which the general set had only 1 and 2 of.

`candidates.jsonl` holds all of them.

## Rebuild

```sh
python3 -m venv /tmp/cmu && /tmp/cmu/bin/pip install cmudict
/tmp/cmu/bin/python tools/practice/order_lines.py tools/practice/candidates.jsonl > Hex/Resources/Data/practice_lines.json
```

Line IDs are a hash of the text, so a rebuild can reorder or add lines without losing recorded progress; editing a line's text makes it a new line.

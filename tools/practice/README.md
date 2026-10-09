# Practice script

`Hex/Resources/Data/practice_lines.json` is the read-aloud script in Settings › Practice. Each line carries its sounds (CMU phoneme counts), sound pairs (diphones, `"AA-B"`) and out-of-dictionary terms. The app doesn't read the script in order: it builds sets of at most ten lines (`PracticePicker`) that fill whatever the recordings so far are missing, from lines not shown before.

| Stage | Lines | What it's for in a set |
|---|---|---|
| `sounds` | ~9 | the fewest lines that hold every English phoneme (CMU, 39) twice |
| `pairs` | ~110 | most new diphones per word, the rule CMU Arctic used |
| `detail` | ~125 | the user's own dictation: jargon, spoken code, numbers, fillers |
| `extra` | rest | general lines that add no new pair |

A set is 3–5 "every sound" slots (any general line, scored by how rare its sounds are in the recordings), 1–3 "sound combinations" slots (unrecorded pairs per word), 1–2 `detail` lines (new pairs + new terms) and one `extra` line. Each slot draws at random from the best three, so sets differ. Endless mode cycles the same slots one line at a time.

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

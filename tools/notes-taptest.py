#!/usr/bin/env python3
"""Notes mode, tap versus hold (docs/plan.md P3.6 D1), on real engines and a real recording.

Runs the Debug app's `--notes-harness taps` (Hex/App/NotesTapHarness.swift) once per scenario against a
scratch data root. The harness feeds key events through the real hotkey effect (NotesTapDetector +
HotKeyProcessor), cuts the held time out of a WAV instead of recording, and replaces paste and sounds with
log lines; transcription, the Notes engine and the rewrite are live. Nothing is pasted, no key is pressed
and the user's data root and settings are never opened.

  tap-starts-session     press, release after 0.15 s: no dictation; a session records the feed for a
                         minute; a second tap stops it; the session has a transcript of that minute
  hold-is-dictation      hold 4 s: one Raw dictation, text matches the excerpt (Cohere as the independent
                         opinion), no session, the "dictating as" state was reached
  boundary               release at 0.25 s: session; release at 0.40 s: dictation
  quick-second-tap       tap to start, tap again 3 s in: session discarded, no folder left
  hold-clean (--clean)   hold 4 s with Clean picked before Notes: one dictation rewritten on device

Usage: tools/notes-taptest.py [--wav FEED.wav] [--only NAME,...] [--minute 60] [--clean] [--keep] [--app PATH]
Build first: xcodebuild -scheme Hex -configuration Debug -skipMacroValidation -skipPackagePluginValidation build
Exit status 1 if any scenario fails.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

DATA = os.path.expanduser("~/Library/Application Support/LegacyScribe")
DEFAULT_WAV = os.path.join(DATA, "bench", "overnight-inputs", "qa-10min.wav")
DEFAULT_APP = glob.glob(os.path.expanduser(
    "~/Library/Developer/Xcode/DerivedData/Hex-*/Build/Products/Debug/LegacyScribe Debug.app/Contents/MacOS/LegacyScribe Debug"))


def words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def wer(reference, hypothesis):
    r, h = words(reference), words(hypothesis)
    if not r:
        return 0.0 if not h else 1.0
    row = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        previous, row[0] = row[0], i
        for j, hw in enumerate(h, 1):
            previous, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, previous + (rw != hw))
    return row[-1] / len(r)


class Run:
    def __init__(self, app, wav, script, extra, timeout):
        self.root = tempfile.mkdtemp(prefix="lsnotes-taps-")
        os.symlink(os.path.join(DATA, "Models"), os.path.join(self.root, "Models"))
        self.log_path = os.path.join(self.root, "harness.log")
        self.started = time.time()
        with open(self.log_path, "w") as log:
            process = subprocess.Popen(
                [app, "--notes-harness", "taps", wav, "--script", script, "--timeout", str(timeout)] + extra,
                stdout=log, stderr=subprocess.DEVNULL, env=dict(os.environ, LEGACYSCRIBE_DATA_ROOT=self.root))
            try:
                process.wait(timeout=timeout + 120)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        self.returncode = process.returncode
        self.seconds = time.time() - self.started
        self.events = []
        with open(self.log_path) as f:
            for line in f:
                if line.startswith("{"):
                    try:
                        self.events.append(json.loads(line))
                    except ValueError:
                        pass

    def of(self, name):
        return [e for e in self.events if e["event"] == name]

    @property
    def summary(self):
        found = self.of("summary")
        return found[0] if found else {}

    def session_seconds(self):
        """Audio seconds the kept sessions' transcript lines cover (each line stores its chunk's seconds)."""
        total = 0.0
        for path in glob.glob(os.path.join(self.root, "Notes", "*", "transcript.jsonl")):
            with open(path) as f:
                for line in f:
                    if line.strip():
                        total += json.loads(line).get("seconds") or 0
        return total

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


# Each scenario returns (ok, evidence).

def tap_starts_session(run):
    s, release = run.summary, run.of("key.release")
    problems = []
    if run.returncode != 0 or not s:
        return False, "harness failed (%s)" % run.returncode
    if s["pasted"] or s["history"] or run.of("transcribe"):
        problems.append("a dictation ran (pasted %d, transcribe %d)" % (len(s["pasted"]), len(run.of("transcribe"))))
    if len(run.of("notes.start")) != 1 or len(run.of("notes.stop")) != 1 or run.of("notes.discard"):
        problems.append("notes calls start/stop/discard = %d/%d/%d" % (
            len(run.of("notes.start")), len(run.of("notes.stop")), len(run.of("notes.discard"))))
    if len(s["notesFolders"]) != 1 or len(s["sessions"]) != 1:
        problems.append("folders %s" % s["notesFolders"])
        return False, "; ".join(problems)
    session = s["sessions"][0]
    seconds = run.session_seconds()
    start, stop = run.of("notes.start")[0]["t"], run.of("notes.stop")[0]["t"]
    if session["transcriptWords"] < 60 or session["pendingChunks"]:
        problems.append("transcript %d words, %d pending" % (session["transcriptWords"], session["pendingChunks"]))
    if not (50 <= seconds <= 70):
        problems.append("transcript covers %.0f s" % seconds)
    held = release[0]["heldSeconds"] if release else None
    evidence = ("tap held %.2f s; pasted 0, transcribes 0; session %s %.0f s (notes.start t=%.1f, stop t=%.1f), "
                "%d chunks, %d words, speakers %d, stage %s%s") % (
        held, session["id"], seconds, start, stop, session["transcribedChunks"], session["transcriptWords"],
        session["speakers"], session["stage"], "" if not session["notesError"] else " (notes error: %s)" % session["notesError"])
    return not problems, evidence + ("" if not problems else " | " + "; ".join(problems))


def hold_dictation(run, *, clean=False, check_reference=True):
    s = run.summary
    if run.returncode != 0 or not s:
        return False, "harness failed (%s)" % run.returncode
    problems = []
    stops, transcribes = run.of("recording.stop"), run.of("transcribe")
    states = run.of("state")
    if run.of("notes.start") or s["notesFolders"] or s["sessions"]:
        problems.append("a session exists %s" % s["notesFolders"])
    if len(stops) != 1 or len(transcribes) != 1 or len(s["pasted"]) != 1:
        problems.append("stops/transcribes/pastes = %d/%d/%d" % (len(stops), len(transcribes), len(s["pasted"])))
        return False, "; ".join(problems)
    held = stops[0]["heldSeconds"]
    if not (3.9 <= held <= 4.4):
        problems.append("held %.2f s" % held)
    if not states or not states[0].get("notesHold"):
        problems.append("hold state never reached (dictating as)")
    press = run.of("key.press")[0]["t"]
    sounds = [e for e in run.of("sound") if e["name"] == "startRecording"]
    if len(sounds) != 1 or not (press + 0.25 <= sounds[0]["t"] <= press + 0.6):
        problems.append("start sound %s" % [e["t"] for e in sounds])
    entry = s["history"][0]
    mode = entry["rewriteMode"]
    if clean:
        if mode != "clean" or not entry["rewrittenBy"]:
            problems.append("history rewriteMode=%r rewrittenBy=%r" % (mode, entry["rewrittenBy"]))
        paste_t = run.of("paste")[0]["t"]
        total = paste_t - run.of("key.release")[0]["t"]
        if total > 10:
            problems.append("key-up to paste %.1f s" % total)
    elif mode:
        problems.append("rewriteMode=%r in Raw" % mode)
    text = s["pasted"][0]
    score = None
    if check_reference and s["references"]:
        reference = s["references"][0]["referenceText"]
        score = wer(reference, s["references"][0]["engineText"])
        if score > 0.35:
            problems.append("differs from Cohere's reading, WER %.0f%%" % (score * 100))
    elif check_reference:
        problems.append("no reference")
    evidence = "held %.2f s from file s%d; hold state reached (start sound t=%.2f); 1 transcribe, 1 paste, no session; pasted %r" % (
        held, int(stops[0]["fromSecond"]), sounds[0]["t"] - press if sounds else -1, text)
    if score is not None:
        evidence += "; Cohere reads %r, WER %.0f%%" % (s["references"][0]["referenceText"], score * 100)
    if clean:
        evidence += "; Clean by %s, raw %r, key-up to paste %.1f s" % (
            entry["rewrittenBy"], entry["rawText"], run.of("paste")[0]["t"] - run.of("key.release")[0]["t"])
    return not problems, evidence + ("" if not problems else " | " + "; ".join(problems))


def boundary(shorter, longer):
    """Two runs: `shorter` released at 0.25 s must start a session; `longer` at 0.40 s must dictate."""
    s, problems = shorter.summary, []
    if shorter.returncode != 0 or not s or longer.returncode != 0 or not longer.summary:
        return False, "harness failed (%s/%s)" % (shorter.returncode, longer.returncode)
    held_short = shorter.of("key.release")[0]["heldSeconds"]
    held_long = longer.of("key.release")[0]["heldSeconds"]
    if len(shorter.of("notes.start")) != 1 or shorter.of("transcribe") or shorter.summary["pasted"]:
        problems.append("%.2f s release: notes.start %d, transcribes %d" % (
            held_short, len(shorter.of("notes.start")), len(shorter.of("transcribe"))))
    if len(s["sessions"]) != 1 or len(s["notesFolders"]) != 1:
        problems.append("%.2f s release: folders %s" % (held_short, s["notesFolders"]))
    l = longer.summary
    if longer.of("notes.start") or l["notesFolders"] or l["sessions"]:
        problems.append("%.2f s release started a session" % held_long)
    if len(longer.of("recording.stop")) != 1 or len(longer.of("transcribe")) != 1:
        problems.append("%.2f s release: stops %d, transcribes %d" % (
            held_long, len(longer.of("recording.stop")), len(longer.of("transcribe"))))
    session = s["sessions"][0] if s["sessions"] else {}
    evidence = ("%.2f s release: session %s (%d words kept after its stop); %.2f s release: dictation, %d transcribe, no session, "
                "%d paste (%r)") % (
        held_short, session.get("id", "-"), session.get("transcriptWords", 0), held_long,
        len(longer.of("transcribe")), len(l["pasted"]), (l["pasted"] or [""])[0])
    return not problems, evidence + ("" if not problems else " | " + "; ".join(problems))


def quick_second_tap(run):
    s = run.summary
    if run.returncode != 0 or not s:
        return False, "harness failed (%s)" % run.returncode
    problems = []
    starts, stops, discards = run.of("notes.start"), run.of("notes.stop"), run.of("notes.discard")
    if len(starts) != 1 or len(discards) != 1 or stops:
        problems.append("notes start/stop/discard = %d/%d/%d" % (len(starts), len(stops), len(discards)))
    if s["notesFolders"] or s["sessions"]:
        problems.append("left behind: folders %s, sessions %d" % (s["notesFolders"], len(s["sessions"])))
    if s["pasted"] or run.of("transcribe"):
        problems.append("a dictation ran")
    lived = discards[0]["t"] - starts[0]["t"] if starts and discards else -1
    evidence = "session lived %.1f s (rule: under 5 s); discard 1, stop 0; Notes folders %s; pasted %d" % (
        lived, s["notesFolders"], len(s["pasted"]))
    return not problems, evidence + ("" if not problems else " | " + "; ".join(problems))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wav", default=DEFAULT_WAV)
    parser.add_argument("--app", default=DEFAULT_APP[0] if DEFAULT_APP else None)
    parser.add_argument("--only", default="")
    parser.add_argument("--minute", type=float, default=60, help="seconds a session records in the first scenario")
    parser.add_argument("--offset", type=float, default=60,
                        help="where in the WAV dictations are cut from (60 s: one clear voice; at 55 s and 100 s the engines disagree on crosstalk)")
    parser.add_argument("--clean", action="store_true", help="also hold with Clean picked before Notes (on-device 4B)")
    parser.add_argument("--keep", action="store_true", help="keep the scratch roots and logs")
    parser.add_argument("--json", help="write the results here as JSON")
    args = parser.parse_args()
    if not args.app or not os.path.exists(args.app):
        sys.exit("Debug app not found; build it first (see the docstring)")
    if not os.path.exists(args.wav):
        sys.exit("feed not found: " + args.wav)
    only = set(filter(None, args.only.split(",")))
    base = ["--offset", str(args.offset)]
    results, runs = [], []

    def go(script, extra=(), timeout=120):
        run = Run(args.app, args.wav, script, base + list(extra), timeout)
        runs.append(run)
        return run

    def wanted(name):
        return not only or name in only

    if wanted("tap-starts-session"):
        run = go("p; w 0.15; r; w %g; p; w 0.15; r" % args.minute, ["--feed-offset", "0", "--until", "done"],
                 timeout=int(args.minute) + 240)
        results.append(("tap-starts-session", *tap_starts_session(run)))
    if wanted("hold-is-dictation"):
        run = go("p; w 1.0; s; w 3.0; r; w 0.2; s", ["--reference"])
        results.append(("hold-is-dictation", *hold_dictation(run)))
    if wanted("boundary"):
        short = go("p; w 0.25; r; w 6; p; w 0.15; r", ["--feed-offset", "0"])
        long = go("p; w 0.40; r; w 0.2; s")
        results.append(("boundary", *boundary(short, long)))
    if wanted("quick-second-tap"):
        run = go("p; w 0.15; r; w 3; p; w 0.15; r")
        results.append(("quick-second-tap", *quick_second_tap(run)))
    if args.clean and wanted("hold-clean"):
        run = go("p; w 1.0; s; w 3.0; r; w 0.2; s", ["--before", "clean", "--reference"])
        results.append(("hold-clean", *hold_dictation(run, clean=True)))

    width = max([len(r[0]) for r in results] + [8])
    print()
    print("%-*s  %-4s  %s" % (width, "scenario", "", "evidence"))
    for name, ok, evidence in results:
        print("%-*s  %-4s  %s" % (width, name, "PASS" if ok else "FAIL", evidence))
    if args.json:
        with open(args.json, "w") as f:
            json.dump([{"scenario": n, "pass": ok, "evidence": e} for n, ok, e in results], f, indent=1)
    for run in runs:
        if args.keep:
            print("kept", run.root)
        else:
            run.cleanup()
    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()

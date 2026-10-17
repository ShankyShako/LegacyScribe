#!/usr/bin/env python3
"""Notes mode data-safety and memory checks (docs/plan.md, "Notes mode" > Verify).

Drives the Debug app's headless notes harness (`--notes-harness`, Hex/App/NotesHarness.swift) against
scratch data roots, so the user's sessions are never touched:

  reference   one uninterrupted session: the expected transcript, chunk by chunk
  kill-*      kill -9 while recording, while transcribing, while writing notes; then resume
  reset       forced Cohere failures (chunk A fails once, chunk B twice) in one session
  memory      peak footprint while transcribing a 10-minute vs a 2-hour feed

A killed session passes when, after the resume, its transcript holds exactly the chunks that were on disk
at the kill (transcribed or pending), once each, with the reference text, nothing is left in pending/, and
notes.md exists. Audio still in memory at the kill (under 30 s) is lost by design.

Usage: tools/notes-crashtest.py FEED_10MIN.wav [--long FEED_2H.wav] [--app PATH] [--only CASE,...]
                                [--voiceprints DIR]  (a Voiceprints folder to copy into each root, so "You" is labelled)
Build first: xcodebuild -scheme Hex -configuration Debug ... build
"""

import argparse
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

DATA = os.path.expanduser("~/Library/Application Support/LegacyScribe")
VOICEPRINTS = None
DEFAULT_APP = glob.glob(os.path.expanduser(
    "~/Library/Developer/Xcode/DerivedData/Hex-*/Build/Products/Debug/LegacyScribe Debug.app/Contents/MacOS/LegacyScribe Debug"))


class Run:
    """One harness process writing JSON lines to a log file."""

    def __init__(self, app, root, args, env=None):
        self.log_path = os.path.join(root, "harness-%d.log" % time.time_ns())
        self.log = open(self.log_path, "w")
        environment = dict(os.environ, LEGACYSCRIBE_DATA_ROOT=root, **(env or {}))
        self.process = subprocess.Popen([app, "--notes-harness"] + args, stdout=self.log,
                                        stderr=subprocess.DEVNULL, env=environment)

    def events(self):
        events = []
        with open(self.log_path) as f:
            for line in f:
                if not line.endswith("\n"):
                    break  # still being written
                if line.startswith("{"):
                    events.append(json.loads(line))
        return events

    def wait_for(self, predicate, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if any(predicate(e) for e in self.events()):
                return True
            if self.process.poll() is not None:
                return any(predicate(e) for e in self.events())
            time.sleep(0.05)
        return False

    def kill(self):
        self.process.send_signal(signal.SIGKILL)
        self.process.wait()

    def finish(self, timeout):
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            raise SystemExit("harness timed out: " + self.log_path)
        if self.process.returncode != 0:
            raise SystemExit("harness failed (%d): %s" % (self.process.returncode, self.log_path))


def scratch_root(name):
    root = tempfile.mkdtemp(prefix="lsnotes-%s-" % name)
    os.symlink(os.path.join(DATA, "Models"), os.path.join(root, "Models"))
    if VOICEPRINTS:
        shutil.copytree(VOICEPRINTS, os.path.join(root, "Voiceprints"))
    return root


def session_folder(root):
    sessions = sorted(os.listdir(os.path.join(root, "Notes")))
    assert len(sessions) == 1, sessions
    return os.path.join(root, "Notes", sessions[0])


def transcript_lines(folder):
    path = os.path.join(folder, "transcript.jsonl")
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def chunks_on_disk(folder):
    """Chunk indices that exist anywhere on disk: transcribed (in the newest complete transcript file)
    or still pending as a finished WAV."""
    done = set()
    for name in ("transcript.jsonl", "transcript.new", "transcript.bak"):
        path = os.path.join(folder, name)
        if not os.path.exists(path):
            continue
        try:
            with open(path) as f:
                done |= {json.loads(line)["chunk"] for line in f if line.strip()}
        except (ValueError, KeyError):
            pass  # a torn file is what the loader skips too
    pending = {int(os.path.basename(p)[:-4]) for p in glob.glob(os.path.join(folder, "pending", "*.wav"))}
    return done | pending


def check_finished(folder, expected_chunks, reference, label):
    problems = []
    lines = transcript_lines(folder)
    chunks = [line["chunk"] for line in lines]
    if len(chunks) != len(set(chunks)):
        problems.append("duplicated chunks %s" % sorted(c for c in set(chunks) if chunks.count(c) > 1))
    if set(chunks) != expected_chunks:
        problems.append("missing %s, unexpected %s" % (sorted(expected_chunks - set(chunks)), sorted(set(chunks) - expected_chunks)))
    for line in lines:
        want = reference.get(line["chunk"])
        if want is not None and not line.get("gap") and line.get("text", "") != want:
            problems.append("chunk %d text differs from the reference" % line["chunk"])
    leftovers = os.listdir(os.path.join(folder, "pending"))
    if leftovers:
        problems.append("pending/ not empty: %s" % leftovers)
    with open(os.path.join(folder, "session.json")) as f:
        stage = json.load(f)["stage"]
    if stage != "done":
        problems.append("stage is %s" % stage)
    notes = os.path.join(folder, "notes.md")
    if not os.path.exists(notes) or os.path.getsize(notes) == 0:
        problems.append("no notes.md")
    status = "PASS" if not problems else "FAIL"
    print("%-22s %s  %d chunks%s" % (label, status, len(chunks), "" if not problems else "  " + "; ".join(problems)))
    return not problems


def run_reference(app, feed, speed):
    root = scratch_root("reference")
    run = Run(app, root, ["record", feed, "--speed", str(speed)])
    run.finish(timeout=1800)
    folder = session_folder(root)
    reference = {line["chunk"]: line.get("text", "") for line in transcript_lines(folder)}
    print("%-22s %d chunks, %d words" % ("reference", len(reference), sum(len(t.split()) for t in reference.values())))
    return reference


def kill_case(app, feed, reference, label, speed, when, settle=0.0):
    root = scratch_root(label)
    run = Run(app, root, ["record", feed, "--speed", str(speed)])
    if not run.wait_for(when, timeout=1800):
        run.kill()
        print("%-22s SKIP  the stage to kill in never came" % label)
        return False
    time.sleep(settle)
    run.kill()
    folder = session_folder(root)
    on_disk = chunks_on_disk(folder)
    with open(os.path.join(folder, "session.json")) as f:
        stage = json.load(f)["stage"]
    parts_before = {p: open(p).read() for p in glob.glob(os.path.join(folder, "notes", "part-*.md"))}
    resume = Run(app, root, ["resume"])
    resume.finish(timeout=1800)
    ok = check_finished(folder, on_disk, reference, "%s (at %s)" % (label, stage))
    for path, text in parts_before.items():
        if open(path).read() != text:
            print("%-22s FAIL  %s was rewritten after the resume" % ("", os.path.basename(path)))
            ok = False
    if parts_before:
        print("%-22s       %d saved part(s) kept as written" % ("", len(parts_before)))
    return ok


def reset_case(app, feed, reference, speed):
    once, twice = 4, 9
    root = scratch_root("reset")
    run = Run(app, root, ["record", feed, "--speed", str(speed)], env={"LEGACYSCRIBE_NOTES_FAIL": "%dx1,%dx2" % (once, twice)})
    run.finish(timeout=1800)
    folder = session_folder(root)
    lines = {line["chunk"]: line for line in transcript_lines(folder)}
    problems = []
    if lines.get(once, {}).get("text") != reference.get(once):
        problems.append("chunk %d (one failure) should match the reference after the reload" % once)
    if not lines.get(twice, {}).get("gap"):
        problems.append("chunk %d (two failures) should be a gap" % twice)
    if not os.path.exists(os.path.join(folder, "failed", "%05d.wav" % twice)):
        problems.append("failed/%05d.wav missing" % twice)
    expected = set(reference)
    if set(lines) != expected:
        problems.append("chunks differ from the reference")
    stacked = max((e.get("pending", 0) for e in run.events() if e.get("event") == "status"), default=0)
    print("%-22s %s  gap at %d kept in failed/, %d recovered after a reload, up to %d chunks queued%s" % (
        "reset", "PASS" if not problems else "FAIL", twice, once, stacked, "" if not problems else "  " + "; ".join(problems)))
    return not problems


def memory_case(app, feed, label, speed):
    root = scratch_root("memory")
    run = Run(app, root, ["record", feed, "--speed", str(speed)])
    run.finish(timeout=7200)
    events = [e for e in run.events() if e.get("event") == "status"]
    transcribing = [e for e in events if e["stage"] in ("recording", "transcribing")]
    peak = max(e["footprint"] for e in transcribing)
    chunks = max(e["transcribed"] for e in events)
    # The footprint after each chunk, in thirds of the session: flat means the last third isn't higher.
    thirds = [transcribing[i * len(transcribing) // 3:(i + 1) * len(transcribing) // 3] for i in range(3)]
    peaks = [max(e["footprint"] for e in t) / 2**30 for t in thirds if t]
    notes_peak = max((e["footprint"] for e in events if e["stage"] == "noting"), default=0)
    print("%-22s %d chunks, transcribing peak %.2f GB (by third: %s), notes peak %.2f GB" % (
        label, chunks, peak / 2**30, " / ".join("%.2f" % p for p in peaks), notes_peak / 2**30))
    return peak


def main():
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser()
    parser.add_argument("feed")
    parser.add_argument("--long", help="a 2-hour feed for the memory check")
    parser.add_argument("--long-notes-feed", help="a feed long enough for 2+ note parts (kill-noting-parts; ~3,500 words)")
    parser.add_argument("--app", default=DEFAULT_APP[0] if DEFAULT_APP else None)
    parser.add_argument("--only", default="")
    parser.add_argument("--voiceprints", help="a Voiceprints folder (from `--notes-harness enrol`) copied into each scratch root")
    args = parser.parse_args()
    global VOICEPRINTS
    VOICEPRINTS = args.voiceprints
    only = set(filter(None, args.only.split(",")))
    want = lambda name: not only or name in only
    if not args.app or not os.path.exists(args.app):
        raise SystemExit("Debug app not found; build it first or pass --app")

    reference = run_reference(args.app, args.feed, speed=20)
    results = []
    if want("kill-recording"):
        results.append(kill_case(args.app, args.feed, reference, "kill-recording", 20,
                                 lambda e: e.get("stage") == "recording" and e.get("transcribed", 0) >= 6))
    if want("kill-transcribing"):
        # Fed 200x faster than real time, chunks stack up and the drain after stop takes a while.
        results.append(kill_case(args.app, args.feed, reference, "kill-transcribing", 200,
                                 lambda e: e.get("stage") == "transcribing" and e.get("pending", 0) >= 3, settle=0.4))
    if want("kill-noting"):
        # Mid-answer, before any part is saved: the notes start over.
        results.append(kill_case(args.app, args.feed, reference, "kill-noting", 20,
                                 lambda e: e.get("stage") == "noting" and "partsTotal" in e, settle=3))
    if want("kill-noting-parts") and args.long_notes_feed:
        # After the first of several parts is saved: that part is kept, the rest are written.
        notes_reference = run_reference(args.app, args.long_notes_feed, speed=40)
        results.append(kill_case(args.app, args.long_notes_feed, notes_reference, "kill-noting-parts", 40,
                                 lambda e: e.get("stage") == "noting" and e.get("partsDone", 0) >= 1, settle=0.5))
    if want("reset"):
        results.append(reset_case(args.app, args.feed, reference, 20))
    if want("memory"):
        short = memory_case(args.app, args.feed, "memory (feed)", 20)
        if args.long:
            long = memory_case(args.app, args.long, "memory (long feed)", 40)
            flat = long <= short * 1.15
            print("%-22s %s  long peak is %.0f%% of the short peak" % ("memory flat", "PASS" if flat else "FAIL", 100 * long / short))
            results.append(flat)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()

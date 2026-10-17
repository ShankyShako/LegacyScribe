#!/bin/bash
# Overnight job runner: the heavy jobs one after another, while nobody uses the Mac.
#
#   tools/overnight.sh [--only a,b] [--skip a,b] [--dry-run] [--help]
#
# Steps, in order (each logs to <data root>/overnight/<date>/<step>.log; a failed step is recorded and
# the next one still runs):
#   idle        D3 idle profile (tools/idle-profile.sh): builds Release, then per configuration
#               quit / set / launch / 2 min warm-up / 5 min of top + footprint / quit. Edits and restores
#               the real hex_settings.json (Release ignores LEGACYSCRIBE_DATA_ROOT).
#   notes-long  signed Debug build, a 2-hour and a 60-minute feed made by looping qa-10min.wav, then
#               tools/notes-crashtest.py with --long, --long-notes-feed and --voiceprints.
#               Inputs live in <data root>/bench/overnight-inputs/ (copied from /tmp on the first run,
#               because /tmp is wiped on reboot).
#   label-27b   resumes the qwen3.6:27b Notes labeller (.claude/handoff.md) in the foreground, once the
#               GPU is free. Never run it next to MLX training.
#   finetune-17b  trains the 4-bit Qwen3-1.7B on the dictation pool plus the Notes pieces label-27b has
#               labelled (tools/finetune/build_notes_mix.py, validation set unchanged), picks the
#               checkpoint with the lowest validation loss, fuses it to 4-bit (scribe-1.7b-qnotes-4bit),
#               scores it like out-q17-para.json (lsbench rewrite + score.py) and logs the WER and best
#               val loss next to the old 29.7 / 0.340. Unloads Ollama's models first and waits for a free
#               GPU. Skipped (status "skipped") when label-27b failed or under 100 pieces pass the filter.
#
# The whole run sits under `caffeinate -i`. At the end: summary.txt in the run folder, and the Release
# LegacyScribe.app that was running at the start (DerivedData's or /Applications') is opened again; which
# one is written to reopen-app.txt.
#
# Do not use the Mac while it runs: the idle step quits LegacyScribe and edits its settings file, and
# the other steps want the GPU and memory to themselves.
set -u -o pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$HOME/Library/Application Support/LegacyScribe"
INPUTS="$DATA/bench/overnight-inputs"
FINETUNE="$DATA/finetune"
ALL_STEPS="idle notes-long label-27b finetune-17b"
DAY="$(date +%F)"
RUN_DIR="$DATA/overnight/$DAY"

ONLY=""
SKIP=""
DRY=0

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --skip) SKIP="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }

for s in $(echo "$ONLY,$SKIP" | tr ',' ' '); do
  in_list "$s" "$(echo "$ALL_STEPS" | tr ' ' ',')" || { echo "unknown step: $s (have: $ALL_STEPS)" >&2; exit 2; }
done

STEPS=""
for s in $ALL_STEPS; do
  if [ -n "$ONLY" ] && ! in_list "$s" "$ONLY"; then continue; fi
  if in_list "$s" "$SKIP"; then continue; fi
  STEPS="$STEPS $s"
done
STEPS="${STEPS# }"
[ -n "$STEPS" ] || { echo "no steps selected" >&2; exit 2; }

say() { echo "[$(date +%H:%M:%S)] $*"; }

# Run a command, or only print it in a dry run.
x() {
  if [ "$DRY" = 1 ]; then echo "    \$ $*"; else echo "+ $*"; "$@"; fi
}

# --- which app was running --------------------------------------------------------------------
app_pid() { pgrep -x LegacyScribe | head -1; }    # exact name; "LegacyScribe Debug" is not matched

detect_app() { # sets APP_PATH and APP_WAS_RUNNING
  local pid; pid="$(app_pid)"
  if [ -n "$pid" ]; then
    APP_WAS_RUNNING=yes
    APP_PATH="$(ps -o comm= -p "$pid" | sed 's#/Contents/MacOS/.*##')"
  else
    APP_WAS_RUNNING=no
    APP_PATH="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Hex-*/Build/Products/Release/LegacyScribe.app 2>/dev/null | head -1)"
    [ -n "$APP_PATH" ] || APP_PATH="/Applications/LegacyScribe.app"
  fi
}
detect_app

# --- steps ------------------------------------------------------------------------------------
step_idle() {
  x "$REPO/tools/idle-profile.sh" --out "$RUN_DIR/idle" --no-reopen
  if [ "$DRY" = 1 ]; then "$REPO/tools/idle-profile.sh" --dry-run --no-reopen --out "$RUN_DIR/idle" | sed 's/^/      | /'; fi
}

stage_inputs() {
  x mkdir -p "$INPUTS"
  if [ ! -f "$INPUTS/qa-10min.wav" ]; then
    [ -f /tmp/crash/qa-10min.wav ] || [ "$DRY" = 1 ] || { echo "no qa-10min.wav in $INPUTS or /tmp/crash"; return 1; }
    x cp -p /tmp/crash/qa-10min.wav "$INPUTS/qa-10min.wav" || return 1
  fi
  if [ ! -d "$INPUTS/Voiceprints" ]; then
    [ -d /tmp/spk-run/root/Voiceprints ] || [ "$DRY" = 1 ] || { echo "no Voiceprints in $INPUTS or /tmp/spk-run/root"; return 1; }
    x cp -Rp /tmp/spk-run/root/Voiceprints "$INPUTS/Voiceprints" || return 1
  fi
}

debug_app_path() { ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Hex-*/Build/Products/Debug/"LegacyScribe Debug.app" 2>/dev/null | head -1; }

step_notes_long() {
  local feeds="$RUN_DIR/feeds" rc=0
  stage_inputs || return 1
  # Signed Debug build in the default DerivedData (an unsigned one there would cost the user their TCC grants).
  if ! ( cd "$REPO" && x xcodebuild -scheme Hex -configuration Debug -skipMacroValidation -skipPackagePluginValidation build ); then
    local old; old="$(debug_app_path)"
    [ -n "$old" ] || { echo "build failed and there is no Debug app"; return 1; }
    echo "WARNING: build failed; testing the existing Debug app ($old, built $(stat -f '%Sm' -t '%F %T' "$old"))"
  fi
  x mkdir -p "$feeds"
  # 12 plays of the 10-minute clip = 2 h; 6 plays = 60 min.
  x ffmpeg -nostdin -y -v error -stream_loop 11 -i "$INPUTS/qa-10min.wav" -c copy "$feeds/qa-2h.wav" || rc=1
  x ffmpeg -nostdin -y -v error -stream_loop 5 -i "$INPUTS/qa-10min.wav" -c copy "$feeds/qa-60min.wav" || rc=1
  if [ "$rc" = 0 ]; then
    x python3 -I "$REPO/tools/notes-crashtest.py" "$INPUTS/qa-10min.wav" \
      --long "$feeds/qa-2h.wav" --long-notes-feed "$feeds/qa-60min.wav" \
      --voiceprints "$INPUTS/Voiceprints" || rc=1
  fi
  x rm -rf "$feeds"
  return $rc
}

gpu_utilisation() { # percent, from the AGX accelerator; empty when unreadable
  ioreg -r -d 1 -c IOAccelerator 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' | head -1 | sed 's/.*=//'
}

gpu_blockers() { # processes that must not share the GPU with the 27B
  pgrep -fl 'mlx_lm|mlx-lm|mlx.*(lora|train)|lsbench|notes-harness|notes-crashtest' | grep -v -e 'overnight.sh' -e pgrep
}

wait_for_free_gpu() {
  local i busy util
  for i in $(seq 1 20); do   # up to ~10 minutes
    busy="$(gpu_blockers)"; util="$(gpu_utilisation)"
    if [ -z "$busy" ] && [ "${util:-0}" -lt 15 ]; then echo "GPU free (utilisation ${util:-?}%)"; return 0; fi
    echo "GPU busy (utilisation ${util:-?}%): ${busy:-no blocking process}; waiting 30 s ($i/20)"
    sleep 30
  done
  return 1
}

ollama_up() { curl -s -m 5 http://localhost:11434/api/tags | grep -q 'qwen3.6:27b'; }

label_progress() { # pieces done / total
  python3 -I - "$FINETUNE/out-27b-notes.json" "$FINETUNE/notes-clean-messages.jsonl" <<'PY'
import json, os, sys
out, msgs = sys.argv[1:3]
done = len(json.load(open(out))["results"]) if os.path.exists(out) else 0
print("%d/%d" % (done, sum(1 for _ in open(msgs))))
PY
}

step_label_27b() {
  if [ "$DRY" = 1 ]; then
    echo "    check: venv python, messages file, Ollama has qwen3.6:27b (opens Ollama if it is down)"
    echo "    check: no MLX training, lsbench or notes harness running and GPU utilisation under 15% (waits up to 10 min, else the step fails)"
    echo "    progress now: $(label_progress)"
    echo "    \$ (cd \"$FINETUNE\" && venv/bin/python -I \"$REPO/tools/finetune/label_local.py\" notes-clean-messages.jsonl out-27b-notes.json >> label-notes.log 2>&1)"
    return 0
  fi
  [ -x "$FINETUNE/venv/bin/python" ] || { echo "no $FINETUNE/venv/bin/python"; return 1; }
  [ -f "$FINETUNE/notes-clean-messages.jsonl" ] || { echo "no notes-clean-messages.jsonl"; return 1; }
  if ! ollama_up; then
    echo "Ollama (or qwen3.6:27b) not reachable; opening Ollama"
    open -g -a Ollama; local i
    for i in $(seq 1 15); do sleep 3; ollama_up && break; done
    ollama_up || { echo "Ollama still not serving qwen3.6:27b"; return 1; }
  fi
  wait_for_free_gpu || { echo "GPU never became free; not starting the labeller"; return 1; }
  echo "progress before: $(label_progress)"
  ( cd "$FINETUNE" && echo "+ venv/bin/python -I $REPO/tools/finetune/label_local.py notes-clean-messages.jsonl out-27b-notes.json >> label-notes.log 2>&1" \
      && venv/bin/python -I "$REPO/tools/finetune/label_local.py" notes-clean-messages.jsonl out-27b-notes.json >> label-notes.log 2>&1 )
  local rc=$?
  echo "progress after: $(label_progress)"
  echo "--- tail of label-notes.log ---"; tail -3 "$FINETUNE/label-notes.log"
  return $rc
}

# --- finetune-17b -------------------------------------------------------------------------------
Q17_BASE="$DATA/Models/mlx/mlx-community/Qwen3-1.7B-4bit"
LSBENCH="/tmp/lsbench-dd/Build/Products/Release/lsbench"
MIN_PIECES=100
SKIP_RC=75   # a step that returns this is recorded as "skipped", not FAILED

notes_mix() { # build the mixed dataset into $1 (prints counts; exit 3 when under MIN_PIECES)
  python3 -I "$REPO/tools/finetune/build_notes_mix.py" "$FINETUNE/data-para" "$FINETUNE/notes-pieces.jsonl" \
    "$FINETUNE/out-27b-notes.json" "$1" --min-kept "$MIN_PIECES"
}

q17_iters() { # $1 = training examples. ~1.5 epochs (where the data-para run bottomed out, step 100 of 262 examples at batch 4) plus a
  # margin to see the loss rise again: 150 steps per 262 examples at an effective batch of 4, rounded up to 25, at most 400.
  local it=$(( (150 * $1 / 262 + 24) / 25 * 25 ))
  [ "$it" -gt 400 ] && it=400; [ "$it" -lt 100 ] && it=100
  echo "$it"
}

label_failed() { # label-27b's last result in today's status.tsv was FAILED
  [ -f "${STATUS:-/nonexistent}" ] && awk -F'\t' '$1=="label-27b"{r=$2} END{exit !(r=="FAILED")}' "$STATUS"
}

ollama_unload_all() { # keep_alive 0 for every model Ollama holds, then wait until /api/ps is empty
  python3 -I - <<'PY'
import json, sys, time, urllib.request
base = "http://localhost:11434"
def loaded():
    return [m["name"] for m in json.load(urllib.request.urlopen(base + "/api/ps", timeout=5))["models"]]
try:
    names = loaded()
except OSError:
    print("Ollama is not running: nothing to unload"); sys.exit(0)
for n in names:
    req = urllib.request.Request(base + "/api/generate", json.dumps({"model": n, "keep_alive": 0}).encode(), {"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=60).read()
    print("asked Ollama to unload", n)
for _ in range(30):
    if not loaded(): print("Ollama holds no model"); sys.exit(0)
    time.sleep(2)
print("Ollama still holds", loaded()); sys.exit(1)
PY
}

best_checkpoint() { # "<step> <val loss>" of the saved checkpoint with the lowest validation loss (earliest on a tie)
  python3 -I - "$1" "$2" <<'PY'
import os, re, sys
log, adir = sys.argv[1:3]
text = re.sub(r"\x1b\[[0-9;]*m", "", open(log, errors="replace").read())
best = None
for m in re.finditer(r"^\s*(\d+)\s+val\s+([0-9.]+)", text, re.M):
    step, val = int(m.group(1)), float(m.group(2))
    if not os.path.exists(os.path.join(adir, "%07d_adapters.safetensors" % step)): continue
    if best is None or val < best[1]: best = (step, val)
if best is None: sys.exit(1)
print(best[0], "%.3f" % best[1])
PY
}

lora_recipe() { # an adapter_config.json without the knobs changed on purpose, for diffing
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); [d.pop(k,None) for k in ("adapter_path","batch_size","grad_accumulation_steps","grad_checkpoint","iters","seed","data","model")]; print(json.dumps(d,sort_keys=True,indent=1))' "$1"
}

ensure_lsbench() {
  [ -x "$LSBENCH" ] && return 0
  echo "lsbench not built at $LSBENCH; building it"
  ( cd "$REPO/tools/lsbench" && xcodebuild -scheme lsbench -configuration Release -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath /tmp/lsbench-dd -skipMacroValidation -skipPackagePluginValidation build ) && [ -x "$LSBENCH" ]
}

step_finetune_17b() {
  local F="$FINETUNE" tmp rc n iters best step val ckpt wer
  if [ "$DRY" = 1 ]; then
    echo "    check: label-27b did not fail earlier in this run; venv, data-para, notes-pieces.jsonl, out-27b-notes.json and the 1.7B base exist"
    echo "    check: at least $MIN_PIECES Notes pieces pass the filter (labelled, not truncated, output 0.6-1.4x the input's words), else status 'skipped'"
    tmp="$(mktemp -d /tmp/ft17-dry.XXXXXX)"
    echo "    dataset if built now ($(label_progress) labelled):"
    notes_mix "$tmp" 2>&1 | sed 's/^/      | /'
    n="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["train"])' "$tmp/mix-counts.json" 2>/dev/null)"
    rm -rf "$tmp"
    iters="$(q17_iters "${n:-262}")"
    echo "    iterations now: $iters for ${n:-?} training examples (recomputed from the final labels at run time)"
    echo "    unload every Ollama model (API keep_alive 0), then wait for a free GPU like label-27b (up to 10 min, else the step fails)"
    echo "    \$ python3 -I tools/finetune/build_notes_mix.py data-para notes-pieces.jsonl out-27b-notes.json data-q17-notes --min-kept $MIN_PIECES"
    echo "    \$ (cd \"$F\" && venv/bin/mlx_lm.lora --model Qwen3-1.7B-4bit --train --data data-q17-notes --adapter-path adapters-q17-notes --iters $iters \\"
    echo "        --batch-size 2 --grad-accumulation-steps 2 --grad-checkpoint --learning-rate 1e-4 --num-layers -1 --mask-prompt \\"
    echo "        --max-seq-length 2048 --seed 17 --save-every 25 --steps-per-eval 25 --steps-per-report 25 --val-batches 25 > train-q17-notes.log 2>&1)"
    echo "    pick the lowest val-loss checkpoint -> best-q17-notes/, then:"
    echo "    \$ (cd \"$F\" && venv/bin/mlx_lm.fuse --model Qwen3-1.7B-4bit --adapter-path best-q17-notes --save-path scribe-1.7b-qnotes-4bit)   # stays 4-bit"
    echo "    \$ $LSBENCH rewrite --model scribe-1.7b-qnotes-4bit --samples eval-chat.jsonl --json out-q17-notes.json --no-think   # builds lsbench first if missing: $( [ -x "$LSBENCH" ] && echo present || echo MISSING )"
    echo "    \$ python3 -I tools/finetune/score.py eval-chat.jsonl out-q17-para.json out-q17-notes.json   # old model beside the new"
    echo "    log line: RESULT finetune-17b: WER ... (qpara 29.7), best val loss ... at step ... (qpara 0.340 at step 100)"
    return 0
  fi
  [ -x "$F/venv/bin/mlx_lm.lora" ] || { echo "no $F/venv/bin/mlx_lm.lora"; return 1; }
  [ -d "$Q17_BASE" ] || { echo "no base model $Q17_BASE"; return 1; }
  [ -f "$F/notes-pieces.jsonl" ] && [ -f "$F/out-27b-notes.json" ] && [ -d "$F/data-para" ] || { echo "missing notes-pieces.jsonl, out-27b-notes.json or data-para"; return 1; }
  if label_failed; then echo "SKIPPED: label-27b failed earlier in this run, so the labels may be incomplete"; return $SKIP_RC; fi

  echo "labels: $(label_progress)"
  rm -rf "$F/data-q17-notes"
  notes_mix "$F/data-q17-notes"; rc=$?
  if [ "$rc" = 3 ]; then echo "SKIPPED: fewer than $MIN_PIECES Notes pieces passed the filter"; return $SKIP_RC; fi
  [ "$rc" = 0 ] || { echo "build_notes_mix.py failed (exit $rc)"; return 1; }
  n="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["train"])' "$F/data-q17-notes/mix-counts.json")"
  iters="$(q17_iters "$n")"
  echo "training examples: $n -> $iters iterations (batch 2 x accumulation 2 = effective 4, as the data-para run)"

  ensure_lsbench || echo "WARNING: no lsbench; training goes ahead, scoring will fail"
  ollama_unload_all || { echo "Ollama still holds a model; not training next to it"; return 1; }
  wait_for_free_gpu || { echo "GPU never became free; not training"; return 1; }

  rm -rf "$F/adapters-q17-notes"
  ( cd "$F" && echo "+ venv/bin/mlx_lm.lora ... --iters $iters --batch-size 2 --grad-accumulation-steps 2 --grad-checkpoint (log: train-q17-notes.log)" \
      && venv/bin/mlx_lm.lora --model "$Q17_BASE" --train --data data-q17-notes --adapter-path adapters-q17-notes \
           --iters "$iters" --batch-size 2 --grad-accumulation-steps 2 --grad-checkpoint \
           --learning-rate 1e-4 --num-layers -1 --mask-prompt --max-seq-length 2048 --seed 17 \
           --save-every 25 --steps-per-eval 25 --steps-per-report 25 --val-batches 25 > train-q17-notes.log 2>&1 ) \
    || { echo "training failed"; sed 's/\x1b\[[0-9;]*m//g' "$F/train-q17-notes.log" | tail -8; return 1; }
  # the recipe should equal adapters-q17-para's apart from the knobs changed on purpose
  diff <(lora_recipe "$F/adapters-q17-para/adapter_config.json") <(lora_recipe "$F/adapters-q17-notes/adapter_config.json") \
    && echo "adapter config matches adapters-q17-para (apart from batch, accumulation, checkpointing, iters, seed, data)" \
    || echo "WARNING: adapter config differs from adapters-q17-para beyond the intended knobs"

  best="$(best_checkpoint "$F/train-q17-notes.log" "$F/adapters-q17-notes")" || { echo "no validation loss with a saved checkpoint in train-q17-notes.log"; return 1; }
  step="${best% *}"; val="${best#* }"; ckpt="$(printf '%07d_adapters.safetensors' "$step")"
  echo "best validation loss $val at step $step (checkpoint $ckpt)"
  rm -rf "$F/best-q17-notes"; mkdir -p "$F/best-q17-notes"
  cp "$F/adapters-q17-notes/adapter_config.json" "$F/best-q17-notes/" && cp "$F/adapters-q17-notes/$ckpt" "$F/best-q17-notes/adapters.safetensors" || return 1

  rm -rf "$F/scribe-1.7b-qnotes-4bit"
  ( cd "$F" && echo "+ venv/bin/mlx_lm.fuse --model $Q17_BASE --adapter-path best-q17-notes --save-path scribe-1.7b-qnotes-4bit" \
      && venv/bin/mlx_lm.fuse --model "$Q17_BASE" --adapter-path best-q17-notes --save-path scribe-1.7b-qnotes-4bit ) || { echo "fuse failed"; return 1; }
  grep -q '"bits": 4' "$F/scribe-1.7b-qnotes-4bit/config.json" || { echo "fused model is not 4-bit"; return 1; }

  [ -x "$LSBENCH" ] || { echo "no lsbench at $LSBENCH"; return 1; }
  ( cd "$F" && echo "+ lsbench rewrite --model scribe-1.7b-qnotes-4bit --samples eval-chat.jsonl --json out-q17-notes.json --no-think" \
      && "$LSBENCH" rewrite --model "$F/scribe-1.7b-qnotes-4bit" --samples eval-chat.jsonl --json out-q17-notes.json --no-think 2>&1 | tail -5 ) \
    || { echo "lsbench rewrite failed"; return 1; }
  echo "--- score.py (old qpara first, new qnotes second) ---"
  python3 -I "$REPO/tools/finetune/score.py" "$F/eval-chat.jsonl" "$F/out-q17-para.json" "$F/out-q17-notes.json" | tee "$F/score-q17-notes.txt"
  wer="$(awk '$1=="scribe-1.7b-qnotes-4bit"{print $2}' "$F/score-q17-notes.txt")"
  echo "RESULT finetune-17b: WER ${wer:-?} (qpara 29.7); best val loss $val at step $step (qpara 0.340 at step 100); $n training examples, $iters iterations"
  [ -n "$wer" ]
}

# --- plan / dry run ---------------------------------------------------------------------------
estimate() {
  case "$1" in
    idle)       echo "about 60-75 min: Release build 5-15 min + 5 configs x ~8.5 min" ;;
    notes-long) echo "about 90-120 min: Debug build 5-15 min, feeds, crash test with a 2 h feed" ;;
    label-27b)
      local left; left="$(label_progress 2>/dev/null | awk -F'[/]' '{print $2-$1}')"
      echo "about $(( ${left:-350} * 16 / 60 )) min: ${left:-?} pieces left at ~16 s each" ;;
    finetune-17b)
      local k=0 lab tot proj it
      k="$(notes_mix "$(mktemp -u /tmp/ft17-est.XXXXXX)" 2>/dev/null | sed -n 's/^\([0-9]*\) of .*/\1/p')"; rm -rf /tmp/ft17-est.*
      lab="$(label_progress 2>/dev/null)"; tot="${lab#*/}"; lab="${lab%/*}"
      proj="${k:-0}"
      if in_list label-27b "$(echo "$STEPS" | tr ' ' ',')" && [ "${lab:-0}" -gt 0 ]; then proj=$(( proj * tot / lab )); fi
      it="$(q17_iters $(( 262 + proj )))"
      echo "about $(( it / 60 + 4 ))-$(( it * 3 / 60 + 15 )) min: ~$proj Notes pieces kept by the end, $it iterations at 1-3 s each, plus unload/GPU wait, fuse, scoring" ;;
  esac
}

if [ "$DRY" = 1 ]; then
  say "overnight plan (dry run, nothing is changed or started)"
  echo "  steps        : $STEPS"
  echo "  run folder   : $RUN_DIR   (logs <step>.log, summary.txt, reopen-app.txt)"
  echo "  keep awake   : caffeinate -i  (re-executes this script under it)"
  echo "  app          : running now: $APP_WAS_RUNNING; reopened at the end: $APP_PATH"
  echo "  inputs       : $INPUTS $( [ -f "$INPUTS/qa-10min.wav" ] && [ -d "$INPUTS/Voiceprints" ] && echo '(present)' || echo '(missing: copied from /tmp on the first run)')"
  for s in $STEPS; do
    echo
    echo "step $s  ($(estimate "$s"))"
    echo "    log: $RUN_DIR/$s.log"
    case "$s" in idle) step_idle ;; notes-long) step_notes_long ;; label-27b) step_label_27b ;; finetune-17b) step_finetune_17b ;; esac
  done
  echo
  echo "end: write $RUN_DIR/summary.txt, open $APP_PATH"
  exit 0
fi

# --- real run ---------------------------------------------------------------------------------
if [ -z "${OVERNIGHT_CAFFEINATED:-}" ]; then
  exec caffeinate -i env OVERNIGHT_CAFFEINATED=1 "$0" "$@"
fi

mkdir -p "$RUN_DIR"
STATUS="$RUN_DIR/status.tsv"
printf 'step\tresult\texit\tstarted\tseconds\n' >> "$STATUS"
{
  echo "running at start: $APP_WAS_RUNNING"
  echo "app to reopen: $APP_PATH"
  echo "started: $(date '+%F %T')"
} > "$RUN_DIR/reopen-app.txt"
START_EPOCH="$(date +%s)"
CHILD=""
ABORTED=0

kill_tree() {
  local p c
  for p in "$@"; do
    for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
    kill -TERM "$p" 2>/dev/null
  done
}
on_signal() { ABORTED=1; say "signal received: stopping the current step, then finishing up"; [ -n "$CHILD" ] && kill_tree "$CHILD"; }
trap on_signal INT TERM

run_step() {
  local s="$1" log="$RUN_DIR/$1.log" t0 rc fn
  fn="step_$(echo "$s" | tr '-' '_')"
  t0="$(date +%s)"
  say "step $s started, log $log"
  { echo "=== $s started $(date '+%F %T') ==="; } >> "$log"
  ( "$fn" ) >> "$log" 2>&1 &
  CHILD=$!
  wait "$CHILD"; rc=$?
  # a trapped signal makes `wait` return early; collect the real status
  while kill -0 "$CHILD" 2>/dev/null; do wait "$CHILD" 2>/dev/null; rc=$?; sleep 1; done
  CHILD=""
  echo "=== $s finished $(date '+%F %T') exit $rc ===" >> "$log"
  local res; case "$rc" in 0) res=ok ;; "$SKIP_RC") res=skipped ;; *) res=FAILED ;; esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$res" "$rc" "$(date -r "$t0" +%T)" "$(( $(date +%s) - t0 ))" >> "$STATUS"
  say "step $s $([ "$res" = FAILED ] && echo "FAILED (exit $rc)" || echo "$res")"
}

for s in $STEPS; do
  [ "$ABORTED" = 1 ] && { printf '%s\tskipped (aborted)\t-\t-\t-\n' "$s" >> "$STATUS"; continue; }
  run_step "$s"
done

# --- summary and reopening the app --------------------------------------------------------------
SUMMARY="$RUN_DIR/summary.txt"
{
  echo "Overnight run $DAY, started $(date -r "$START_EPOCH" '+%F %T'), finished $(date '+%F %T')$([ "$ABORTED" = 1 ] && echo ' (aborted)')"
  echo
  column -t -s "$(printf '\t')" "$STATUS"
  if in_list idle "$(echo "$STEPS" | tr ' ' ',')" && [ -f "$RUN_DIR/idle/idle-table.txt" ]; then
    echo; echo "--- idle (D3) ---"; cat "$RUN_DIR/idle/idle-table.txt"
  fi
  if [ -f "$RUN_DIR/notes-long.log" ]; then
    echo; echo "--- notes-long: crash test results ---"
    grep -E 'PASS|FAIL|memory|reference|peak' "$RUN_DIR/notes-long.log" | grep -v '^+' | tail -20
  fi
  if [ -f "$RUN_DIR/label-27b.log" ]; then
    echo; echo "--- label-27b ---"
    grep -E 'progress (before|after)|GPU|not ' "$RUN_DIR/label-27b.log" | tail -6
  fi
  if [ -f "$RUN_DIR/finetune-17b.log" ]; then
    echo; echo "--- finetune-17b (reference scribe-1.7b-qpara-4bit: WER 29.7, val loss 0.340 at step 100) ---"
    grep -E 'RESULT|SKIPPED|Notes pieces kept|^train |best validation|^model |^scribe-1\.7b|WARNING' "$RUN_DIR/finetune-17b.log" | grep -v '^+' | tail -10
  fi
  echo; echo "Logs: $RUN_DIR/<step>.log; idle detail: $RUN_DIR/idle/"
} > "$SUMMARY"

if [ -z "$(app_pid)" ] && [ -d "$APP_PATH" ]; then
  say "reopening $APP_PATH"
  open "$APP_PATH" && echo "reopened: $APP_PATH ($(date +%T))" >> "$RUN_DIR/reopen-app.txt"
else
  echo "app already running at the end, not reopened ($(date +%T))" >> "$RUN_DIR/reopen-app.txt"
fi
cat "$SUMMARY"
grep -q FAILED "$STATUS" && exit 1
exit 0

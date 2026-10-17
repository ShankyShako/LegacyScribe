#!/bin/bash
# D3 idle profile (docs/plan.md, P3.6 "D3. Lighter at rest"): how much does the Release app cost while
# nobody uses it? One row per configuration: median CPU %, idle wakeups per second, power, footprint.
#
# What can wake an idle app (read from the code, 2026-10-16):
#  - KeyEventMonitorClient.watchPermissions: polls Accessibility + Input Monitoring trust every 2 s once
#    both are granted (every 100 ms while one is missing). The only steady poll found: ~0.5 wakeups/s.
#  - Three `while !cancelled { sleep 60 }` keep-alive loops (AppFeature paste-last monitor,
#    TranscriptionFeature sent-edit monitor and Esc monitor): ~3 wakeups/min.
#  - AudioRetentionSweep: one run at launch, then a Task.sleep of 6 h (AppFeature `.task`).
#  - Sparkle (AppUpdater): SUScheduledCheckInterval 86400 s, one check a day. Not started in Debug;
#    Private mode makes the check throw before any socket opens.
#  - Warm microphone (`superFastModeEnabled`, default off): an AVAudioEngine runs between dictations
#    and is rebuilt (debounced 250 ms) on every audio-device change. The engine is torn down while the
#    screen is locked or asleep, so a locked screen makes the "fast mic" rows look cheaper than they are:
#    this script keeps the display awake (caffeinate -d) and warns if the screen is locked.
#  - Loaded models: Parakeet / WhisperKit load at launch and stay (Core ML keeps most memory outside the
#    process); Cohere and the on-device rewrite model load on key-down and unload after the transcript.
#    Apple Speech needs no load. Nothing here wakes the app; it only changes the footprint.
#  - Event tap (CGEventTap on the main run loop): wakes the app on every key/modifier event system-wide,
#    so a person typing nearby adds wakeups. Run it with nobody at the keyboard. No setting turns it off.
#  - SoundEffect output engine stops 10 s after playback; menu bar item / MenuBarExtra: passive.
#  - Notes timers (60 s ticks) and the meter task (100 ms) exist only while recording.
#
# Configurations (only settings the user can reach in Settings; everything else stays as the user has it):
#   baseline        Parakeet v3, microphone off between dictations
#   fastmic         Parakeet v3, "Keep the microphone ready" on
#   cohere          Cohere 4-bit selected, microphone off
#   cohere-fastmic  Cohere 4-bit selected, microphone ready
#   private         Parakeet v3, Private mode on (no update checks)
#
# Release builds ignore LEGACYSCRIBE_DATA_ROOT (StoragePaths honours it in DEBUG only), so the real
# hex_settings.json is edited: it is backed up first and restored by a trap on EXIT/INT/TERM. A stale
# backup left by a killed run (SIGKILL, power cut) is restored the next time this script starts.
#
# Per configuration: quit the app, set the settings, launch, wait --warmup (120 s), sample --sample
# (300 s) with `top -l`, `footprint` once, quit. top's IDLEW is a running total, so wakeups/s is
# (last - first) / duration. POWER is top's unprivileged estimate (it tracks %CPU).
#
# Usage: tools/idle-profile.sh [--out DIR] [--configs a,b] [--warmup S] [--sample S] [--interval S]
#                              [--app PATH] [--no-build] [--no-reopen] [--dry-run] [--help]
set -u -o pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$HOME/Library/Application Support/LegacyScribe"
SETTINGS="$DATA/hex_settings.json"
STALE_BACKUP="$DATA/overnight/hex_settings.json.pre-idle"
BUNDLE_ID="com.genovamongalo.LegacyScribe"
ALL_CONFIGS="baseline,fastmic,cohere,cohere-fastmic,private"

OUT="$DATA/overnight/$(date +%F)/idle"
CONFIGS="$ALL_CONFIGS"
WARMUP=120
SAMPLE=300
INTERVAL=5
APP=""
BUILD=1
REOPEN=1
DRY=0

usage() { sed -n '/^# Usage:/,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; echo "Configs: $ALL_CONFIGS"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --configs) CONFIGS="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --sample) SAMPLE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --no-reopen) REOPEN=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

config_settings() { # name -> "key=json ..." (empty for an unknown name)
  case "$1" in
    baseline)       echo 'selectedModel="parakeet-tdt-0.6b-v3-coreml" superFastModeEnabled=false privateMode=false' ;;
    fastmic)        echo 'selectedModel="parakeet-tdt-0.6b-v3-coreml" superFastModeEnabled=true privateMode=false' ;;
    cohere)         echo 'selectedModel="cohere-transcribe-03-2026-mlx-4bit" superFastModeEnabled=false privateMode=false' ;;
    cohere-fastmic) echo 'selectedModel="cohere-transcribe-03-2026-mlx-4bit" superFastModeEnabled=true privateMode=false' ;;
    private)        echo 'selectedModel="parakeet-tdt-0.6b-v3-coreml" superFastModeEnabled=false privateMode=true' ;;
  esac
}

IFS=',' read -r -a CONFIG_LIST <<< "$CONFIGS"
for c in "${CONFIG_LIST[@]}"; do
  [ -n "$(config_settings "$c")" ] || { echo "unknown config: $c (have: $ALL_CONFIGS)" >&2; exit 2; }
done

say() { echo "[$(date +%H:%M:%S)] $*"; }

if [ "$DRY" = 1 ]; then
  say "idle profile plan (dry run, nothing is changed)"
  echo "  output folder : $OUT"
  echo "  settings file : $SETTINGS (backed up to $STALE_BACKUP, restored on EXIT/INT/TERM)"
  echo "  caffeinate    : caffeinate -d -i around the whole step (display stays awake: a locked screen suspends the warm mic)"
  [ "$BUILD" = 1 ] && echo "  build         : cd $REPO && xcodebuild -scheme Hex -configuration Release -skipMacroValidation -skipPackagePluginValidation build   (after quitting the app; default DerivedData, signed)"
  echo "  app           : ${APP:-newest DerivedData/Hex-*/Build/Products/Release/LegacyScribe.app}"
  for c in "${CONFIG_LIST[@]}"; do
    echo "  config $c:"
    echo "      quit app; set $(config_settings "$c") in hex_settings.json; open app; wait ${WARMUP}s"
    echo "      top -l $((SAMPLE / INTERVAL + 1)) -s $INTERVAL -pid <pid> -stats pid,command,cpu,idlew,power,mem; footprint -p <pid>; quit app"
  done
  echo "  then          : write $OUT/idle-table.txt, restore settings$([ "$REOPEN" = 1 ] && echo ', reopen the app that was running at the start')"
  exit 0
fi

# The display must stay awake for the whole step (see the note on the warm microphone above).
if [ -z "${IDLE_CAFFEINATED:-}" ]; then
  exec caffeinate -d -i env IDLE_CAFFEINATED=1 "$0" "$@"
fi

mkdir -p "$OUT" "$DATA/overnight"

app_pid() { pgrep -x LegacyScribe | head -1; }   # exact name: "LegacyScribe Debug" is not matched

running_app_path() {
  local pid; pid="$(app_pid)"
  [ -n "$pid" ] || return 0
  ps -o comm= -p "$pid" | sed 's#/Contents/MacOS/.*##'
}

quit_app() {
  local pid i; pid="$(app_pid)"
  [ -n "$pid" ] || return 0
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
  for i in $(seq 1 30); do [ -z "$(app_pid)" ] && return 0; sleep 1; done
  say "app ignored quit, sending TERM"; kill -TERM "$pid" 2>/dev/null
  for i in $(seq 1 10); do [ -z "$(app_pid)" ] && return 0; sleep 1; done
  kill -KILL "$pid" 2>/dev/null; sleep 1
}

ORIGINAL_APP="$(running_app_path)"
SETTINGS_BACKED_UP=0

restore_settings() {
  if [ -f "$STALE_BACKUP" ]; then
    quit_app
    cp -p "$STALE_BACKUP" "$SETTINGS" && rm -f "$STALE_BACKUP" && say "settings restored from backup"
  fi
}

cleanup() {
  trap - EXIT INT TERM
  restore_settings
  if [ "$REOPEN" = 1 ] && [ -z "$(app_pid)" ]; then
    local target="${ORIGINAL_APP:-$APP}"
    if [ -n "$target" ] && [ -d "$target" ]; then say "reopening $target"; open "$target"; fi
  fi
}
trap cleanup EXIT
trap 'say "interrupted"; exit 130' INT
trap 'say "terminated"; exit 143' TERM

# A backup left by a killed run holds the user's real settings: put them back first.
if [ -f "$STALE_BACKUP" ]; then say "found a stale settings backup from a killed run"; restore_settings; fi

# --- build -------------------------------------------------------------------------------------
find_release_app() { ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Hex-*/Build/Products/Release/LegacyScribe.app 2>/dev/null | head -1; }

if [ "$BUILD" = 1 ] && [ -z "$APP" ]; then
  quit_app    # the build replaces the bundle; never overwrite a running app
  say "building Release (signed, default DerivedData)"
  if ( cd "$REPO" && xcodebuild -scheme Hex -configuration Release -skipMacroValidation -skipPackagePluginValidation build ) > "$OUT/build.log" 2>&1; then
    say "build ok"
  else
    say "BUILD FAILED (see $OUT/build.log); profiling the existing Release build if there is one"
  fi
fi
[ -n "$APP" ] || APP="$(find_release_app)"
[ -d "$APP" ] || { say "no Release app found"; exit 1; }
say "profiling $APP (built $(stat -f '%Sm' -t '%F %T' "$APP"))"

# --- settings ----------------------------------------------------------------------------------
backup_settings() {
  [ "$SETTINGS_BACKED_UP" = 1 ] && return 0
  [ -f "$SETTINGS" ] || { say "no $SETTINGS to back up"; exit 1; }
  cp -p "$SETTINGS" "$STALE_BACKUP" && cp -p "$SETTINGS" "$OUT/hex_settings.json.original" || exit 1
  SETTINGS_BACKED_UP=1
}

apply_settings() { # key=json ...
  python3 -I - "$SETTINGS" "$@" <<'PY'
import json, os, sys
path = sys.argv[1]
d = json.load(open(path))
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    d[k] = json.loads(v)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2, sort_keys=True)
os.replace(tmp, path)
PY
}

summarise() { # top.txt footprint.txt pid duration config -> table row
  python3 -I - "$@" <<'PY'
import re, statistics, sys
top, foot, pid, duration, name = sys.argv[1:6]
cpu, power, idle = [], [], []
for line in open(top):
    f = line.split()
    if len(f) >= 6 and f[0] == pid:
        try:
            cpu.append(float(f[2])); idle.append(int(f[3])); power.append(float(f[4]))
        except ValueError:
            pass
cpu, power, idle = cpu[1:], power[1:], idle[1:] or idle   # first top sample is not a delta
foot_text = open(foot).read() if foot else ""
m = re.search(r"Footprint:\s+([\d.]+)\s*(KB|MB|GB)", foot_text)
mb = float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)] if m else float("nan")
if len(cpu) < 3:
    print("%s\tno samples\t-\t-\t-" % name); sys.exit(0)
wake = (idle[-1] - idle[0]) / float(duration)
print("%s\t%.2f\t%.3f\t%.2f\t%.0f" % (name, statistics.median(cpu), wake, statistics.median(power), mb))
PY
}

TABLE="$OUT/idle-table.tsv"
printf 'config\tmedian_cpu_pct\tidle_wakeups_per_s\tmedian_power\tfootprint_mb\tnotes\n' > "$TABLE"

for c in "${CONFIG_LIST[@]}"; do
  say "=== $c ==="
  quit_app
  backup_settings
  cp -p "$OUT/hex_settings.json.original" "$SETTINGS"      # every config starts from the user's own settings
  # shellcheck disable=SC2046
  apply_settings $(config_settings "$c")
  note=""
  open "$APP"
  pid=""
  for i in $(seq 1 30); do pid="$(app_pid)"; [ -n "$pid" ] && break; sleep 1; done
  if [ -z "$pid" ]; then
    say "app did not start"; printf '%s\tapp did not start\t-\t-\t-\t\n' "$c" >> "$TABLE"; continue
  fi
  say "pid $pid, warming up ${WARMUP}s"
  sleep "$WARMUP"
  if ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked; then
    note="screen locked (warm mic suspended)"; say "WARNING: screen is locked"
  fi
  [ "$(app_pid)" = "$pid" ] || { say "app exited during warm-up"; printf '%s\tapp exited\t-\t-\t-\t\n' "$c" >> "$TABLE"; continue; }
  samples=$((SAMPLE / INTERVAL + 1))
  say "sampling ${SAMPLE}s (top -l $samples -s $INTERVAL)"
  top -l "$samples" -s "$INTERVAL" -pid "$pid" -stats pid,command,cpu,idlew,power,mem > "$OUT/$c.top.txt" 2>&1
  footprint -p "$pid" > "$OUT/$c.footprint.txt" 2>&1 || true
  [ "$(app_pid)" = "$pid" ] || note="$note app exited while sampling"
  row="$(summarise "$OUT/$c.top.txt" "$OUT/$c.footprint.txt" "$pid" "$SAMPLE" "$c")"
  printf '%s\t%s\n' "$row" "$note" >> "$TABLE"
  say "$row"
  quit_app
done

quit_app
restore_settings
{
  echo "Idle profile of $APP"
  echo "warm-up ${WARMUP}s, sampled ${SAMPLE}s every ${INTERVAL}s, $(date '+%F %T'); wakeups/s = change in top's IDLEW over the window"
  column -t -s "$(printf '\t')" "$TABLE"
} | tee "$OUT/idle-table.txt"

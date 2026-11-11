#!/bin/bash
# Guarded runtime tests of EQ Ape's headless mode (run from Terminal: inherits Terminal's audio-capture
# permission; the binary also refuses to start if the TCC preflight is not "granted").
# ALWAYS restores on exit: default output -> "BlackHole 2ch", CamillaDSP service bootstrapped, no
# EQApe / afplay processes left.
#   scripts/runtime-test.sh real [secs]        1: Scarlett + real config, quiet looped sound
#   scripts/runtime-test.sh reload             2: live reload of a copied config (preamp edit while running)
#   scripts/runtime-test.sh follow             3: --follow-default, switch Scarlett <-> MacBook <-> HDMI (no profile)
#   scripts/runtime-test.sh soak [secs]        4: long run on the Scarlett with CPU / memory sampling
#   scripts/runtime-test.sh rate               extra: Scarlett sample rate 48k -> 44.1k -> 48k while running
#   scripts/runtime-test.sh kill9              5: kill -9 during processing, then check leftovers + afplay
cd "$(dirname "$0")/.."
B=.build/arm64-apple-macosx/release/EQApe
UIDN=$(id -u)
# Author-environment knobs: another system-wide EQ service to pause during the test (launchd label,
# optional) and the output device to restore afterwards.
PAUSE_LABEL="${EQAPE_PAUSE_LAUNCHD_LABEL:-}"
RESTORE_OUT="${EQAPE_RESTORE_OUTPUT:-BlackHole 2ch}"
PLIST="$HOME/Library/LaunchAgents/$PAUSE_LABEL.plist"
SCARLETT="Scarlett Solo USB"
REAL="${EQAPE_TEST_CONFIG:?set EQAPE_TEST_CONFIG to an Equalizer APO config file}"
mkdir -p .scratch
LOG=.scratch/$1-$(date +%H%M%S).log
PLAYER=""

restore() {
  [ -n "$PLAYER" ] && kill "$PLAYER" 2>/dev/null
  pkill -f "EQApe --headless" 2>/dev/null
  pkill -f "afplay -v 0.05" 2>/dev/null
  sleep 0.5
  [ "$RATE_TOUCHED" = 1 ] && $B --set-rate "$SCARLETT" 48000
  $B --set-default "$RESTORE_OUT"
  [ -n "$PAUSE_LABEL" ] && { launchctl print gui/$UIDN/$PAUSE_LABEL >/dev/null 2>&1 || launchctl bootstrap gui/$UIDN "$PLIST"; }
  sleep 1
  echo "--- restore check"
  $B --get-default
  $B --list | grep -A0 "$SCARLETT"
  [ -n "$PAUSE_LABEL" ] && { launchctl print gui/$UIDN/$PAUSE_LABEL | grep -E "^\s*state" | head -1; }
  pgrep -fl "EQApe|eqtap|afplay" || echo "no EQApe/eqtap/afplay processes"
}
trap restore EXIT
trap 'exit 130' INT TERM

play_loop() { while true; do afplay -v 0.05 /System/Library/Sounds/Glass.aiff; sleep 0.3; done; }
start_player() { ( sleep 2; play_loop ) & PLAYER=$!; }
stop_player() { [ -n "$PLAYER" ] && kill "$PLAYER" 2>/dev/null; pkill -f "afplay -v 0.05" 2>/dev/null; PLAYER=""; }
run() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # hard timeout wrapper

echo "before:"; $B --get-default
[ -n "$PAUSE_LABEL" ] && { launchctl bootout gui/$UIDN/$PAUSE_LABEL 2>/dev/null; sleep 1; }
$B --set-default "$SCARLETT"

case "$1" in
real)
  SECS=${2:-35}
  start_player
  run $((SECS + 15)) $B --headless --device "$SCARLETT" --config "$REAL" --seconds "$SECS" 2>&1 | tee "$LOG"
  ;;
reload)
  D=.scratch/live
  rm -rf "$D"; mkdir -p "$D"
  cp "$(dirname "$REAL")"/*.txt "$D/"
  start_player
  ( sleep 9;  echo ">>> $(date +%T.%N | cut -c1-12) EDIT: add 'Preamp: -6 dB' to the copy" | tee -a "$LOG"; printf 'Preamp: -6 dB\n' >> "$D/config.txt"
    sleep 8;  echo ">>> $(date +%T.%N | cut -c1-12) EDIT: preamp of the included file -1 -> -13 dB" | tee -a "$LOG"
    perl -pi -e 's/^Preamp: -1 dB/Preamp: -13 dB/' "$(grep -l "^Preamp: -1 dB" "$D"/*.txt | head -1)"
    sleep 8;  echo ">>> $(date +%T.%N | cut -c1-12) EDIT: restore both" | tee -a "$LOG"
    cp "$(dirname "$REAL")"/*.txt "$D/" ) &
  EDITOR_PID=$!
  run 50 $B --headless --device "$SCARLETT" --config "$D/config.txt" --no-headroom --seconds 33 2>&1 \
    | while IFS= read -r l; do echo "$(date +%T.%N | cut -c1-12) $l"; done | tee -a "$LOG"
  wait $EDITOR_PID 2>/dev/null
  ;;
follow)
  S=.scratch/follow-settings.json
  SUID=$($B --list | grep -A1 "$SCARLETT" | sed -n 's/.*UID: //p')
  cat > "$S" <<EOF
{ "version": 1, "enabled": true, "profiles": {
  "$SUID": { "deviceName": "$SCARLETT", "enabled": true, "configPath": "$REAL", "headroomEnabled": true, "headroomDB": 0.5 },
  "BuiltInSpeakerDevice": { "deviceName": "MacBook Pro Speakers", "enabled": true, "configPath": "$REAL", "headroomEnabled": true, "headroomDB": 0.5 }
} }
EOF
  start_player
  ( sleep 10; echo ">>> $(date +%T) switch default -> MacBook Pro Speakers"; $B --set-default "MacBook Pro Speakers"
    sleep 10; echo ">>> $(date +%T) switch default -> $SCARLETT"; $B --set-default "$SCARLETT"
    sleep 10; echo ">>> $(date +%T) switch default -> C34ATILIUSX (HDMI, no profile)"; $B --set-default "C34ATILIUSX"
    sleep 8;  echo ">>> $(date +%T) switch default -> $SCARLETT"; $B --set-default "$SCARLETT" ) 2>&1 | tee -a "$LOG" &
  SW=$!
  run 60 $B --headless --follow-default --settings "$S" --seconds 46 2>&1 \
    | while IFS= read -r l; do echo "$(date +%T) $l"; done | tee -a "$LOG"
  wait $SW 2>/dev/null
  ;;
soak)
  SECS=${2:-300}
  start_player
  run $((SECS + 20)) $B --headless --device "$SCARLETT" --config "$REAL" --seconds "$SECS" > "$LOG" 2>&1 &
  RUNNER=$!
  sleep 3
  P=$(pgrep -f "EQApe --headless" | head -1)
  echo "EQApe pid $P"
  while kill -0 $RUNNER 2>/dev/null; do
    ps -o %cpu=,rss=,time= -p "$P" 2>/dev/null | awk -v t="$(date +%T)" '{print t" cpu% "$1" rss_kB "$2" cputime "$3}' | tee -a "$LOG.ps"
    sleep 15
  done
  tail -4 "$LOG"
  ;;
kill9)
  start_player
  run 40 $B --headless --device "$SCARLETT" --config "$REAL" --seconds 30 > "$LOG" 2>&1 &
  sleep 8
  P=$(pgrep -f "EQApe --headless" | head -1)
  echo "kill -9 $P during processing"; tail -2 "$LOG"
  kill -9 "$P"
  stop_player
  sleep 2
  echo "--- leftovers visible system-wide after kill -9:"
  $B --taps
  echo "--- afplay starts promptly?"
  T0=$(perl -MTime::HiRes=time -e 'print time')
  run 10 afplay -v 0.05 -t 0.5 /System/Library/Sounds/Glass.aiff; RC=$?
  T1=$(perl -MTime::HiRes=time -e 'print time')
  perl -e "printf \"afplay rc %d, took %.2f s (0.5 s requested)\n\", $RC, $T1-$T0"
  ;;
rate)
  start_player
  RATE_TOUCHED=1
  ( sleep 8; echo ">>> $(date +%T) set Scarlett to 44100 Hz"; $B --set-rate "$SCARLETT" 44100
    sleep 8; echo ">>> $(date +%T) set Scarlett back to 48000 Hz"; $B --set-rate "$SCARLETT" 48000 ) 2>&1 | tee -a "$LOG" &
  SW=$!
  run 40 $B --headless --device "$SCARLETT" --config "$REAL" --seconds 24 2>&1 \
    | while IFS= read -r l; do echo "$(date +%T) $l"; done | tee -a "$LOG"
  wait $SW 2>/dev/null
  ;;
*) echo "unknown test $1"; exit 2 ;;
esac

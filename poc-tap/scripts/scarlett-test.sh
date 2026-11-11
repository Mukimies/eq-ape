#!/bin/bash
# Guarded runtime test of eqtap on a real device. ALWAYS restores: default output -> BlackHole 2ch,
# CamillaDSP service bootstrapped again. Usage:
#   scripts/scarlett-test.sh [device-name] [seconds] [extra eqtap run args...]
# Plays a quiet Glass.aiff (afplay -v 0.05) repeatedly while eqtap runs, normal mode then --bypass.
DEV="${1:-Scarlett Solo USB}"; SECS="${2:-12}"; shift 2 2>/dev/null; EXTRA=("$@")
cd "$(dirname "$0")/.."
B=.build/release/eqtap
UIDN=$(id -u)
# Author-environment knobs: another system-wide EQ service to pause during the test (launchd label,
# optional) and the output device to restore afterwards.
PAUSE_LABEL="${EQAPE_PAUSE_LAUNCHD_LABEL:-}"
RESTORE_OUT="${EQAPE_RESTORE_OUTPUT:-BlackHole 2ch}"
PLIST="$HOME/Library/LaunchAgents/$PAUSE_LABEL.plist"
LOG=.scratch/scarlett-test-$(date +%H%M%S).log
PLAYER=""
restore() {
  [ -n "$PLAYER" ] && kill "$PLAYER" 2>/dev/null
  pkill -f "eqtap run" 2>/dev/null
  $B set-default "$RESTORE_OUT"
  [ -n "$PAUSE_LABEL" ] && { launchctl print gui/$UIDN/$PAUSE_LABEL >/dev/null 2>&1 || launchctl bootstrap gui/$UIDN "$PLIST"; }
  sleep 1
  echo "--- restore check"; $B get-default
  [ -n "$PAUSE_LABEL" ] && { launchctl print gui/$UIDN/$PAUSE_LABEL | grep -E "^\s*state"; }
}
trap restore EXIT INT TERM
echo "before:"; $B get-default
[ -n "$PAUSE_LABEL" ] && { launchctl bootout gui/$UIDN/$PAUSE_LABEL 2>/dev/null; sleep 1; }
$B set-default "$DEV"
play_loop() { while true; do afplay -v 0.05 /System/Library/Sounds/Glass.aiff; sleep 0.3; done; }
for MODE in normal bypass; do
  ARGS=(run --device "$DEV" --seconds "$SECS" --start-timeout 5 "${EXTRA[@]}")
  [ $MODE = bypass ] && ARGS+=(--bypass)
  echo "=== $MODE: ${ARGS[*]}" | tee -a "$LOG"
  ( sleep 2; play_loop ) & PLAYER=$!
  perl -e 'alarm shift; exec @ARGV' $((SECS+15)) $B "${ARGS[@]}" 2>&1 | tee -a "$LOG"
  kill $PLAYER 2>/dev/null; pkill -f "afplay -v 0.05" 2>/dev/null; PLAYER=""
  sleep 1
done

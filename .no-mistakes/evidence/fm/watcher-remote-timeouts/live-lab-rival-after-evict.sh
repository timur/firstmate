#!/bin/bash
# Adversarial live drive of the review-round decision: arm X TERMs stalled
# holder A; A exits, but in the same instant a rival B (a live, TERM-ignoring
# process X never signalled) holds the lock with the beacon still stale.
# X must NOT claim it "sent TERM" to B; it must give the ordinary refusal.
# Usage: live-lab-rival-after-evict.sh <checkout-with-bin/fm-watch.sh> <label>
set -u
WT=$1 LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || { mkdir -p "$LAB/state" "$LAB/data" "$LAB/config"; }
mkdir -p "$LAB/tmux"; export TMUX_TMPDIR="$LAB/tmux"; unset TMUX TMUX_PANE
W="$WT/bin/fm-watch.sh"; LIB="$WT/bin/fm-wake-lib.sh"; S="$LAB/state"
write_lock() {  # <pid>
  local id; id=$(FM_STATE_OVERRIDE="$S" /bin/bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$1")
  rm -rf "$S/.watch.lock"; mkdir -p "$S/.watch.lock"
  printf '%s\n' "$1" > "$S/.watch.lock/pid"; printf '%s\n' "$LAB" > "$S/.watch.lock/fm-home"
  printf '%s\n' "$W" > "$S/.watch.lock/watcher-path"; printf '%s\n' "$id" > "$S/.watch.lock/pid-identity"
}
export -f write_lock; export S LAB W LIB
# Holder A: on TERM, starts rival B, hands B the lock, then exits.
/bin/bash -c 'trap '"'"'/bin/bash -c "trap \"\" TERM; exec sleep 120" & echo $! > "$LAB/B.pid"; write_lock $!; exit 0'"'"' TERM; while :; do sleep 0.05; done' &
A=$!; sleep 0.3; write_lock "$A"
touch -t 200001010000 "$S/.last-watcher-beat"
echo "[$LABEL] holder A=$A holds the lock; beacon stale"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_GUARD_GRACE=1 FM_WATCHER_STALL_BOUND=3 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$W" > "$LAB/x.out" 2> "$LAB/x.err"; rc=$?
B=$(cat "$LAB/B.pid" 2>/dev/null)
echo "[$LABEL] arm X rc=$rc; A alive: $(kill -0 $A 2>/dev/null && echo yes || echo no); rival B=$B alive: $(kill -0 "$B" 2>/dev/null && echo yes || echo no); lock pid now: $(cat "$S/.watch.lock/pid")"
echo "[$LABEL] X stdout: $(cat "$LAB/x.out")"
echo "[$LABEL] X stderr: $(cat "$LAB/x.err")"
[ -n "$B" ] && kill -KILL "$B" 2>/dev/null; kill -KILL "$A" 2>/dev/null
rm -rf "$LAB"

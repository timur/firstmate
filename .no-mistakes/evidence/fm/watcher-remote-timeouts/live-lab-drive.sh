#!/bin/bash
# Live lab drive for fm/watcher-remote-timeouts: real OpenSSH, real /bin/bash 3.2,
# real bin/fm-on.sh, bin/fm-secondmate-liveness-lib.sh and bin/fm-watch.sh against
# a disposable marked lab home and a silent TCP peer (accepts, never sends a
# banner - what a just-woken or wedged remote looks like to ssh).
# Usage: live-lab-drive.sh <worktree> <base-checkout>
set -u
WT=$1 BASE=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/bin"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX TMUX_PANE
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; pkill -f "ssh -F $LAB/" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
say() { printf '\n=== %s\n' "$*"; }
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }

# silent peer
perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>0,Listen=>16,ReuseAddr=>1) or die;
  open(my $f,">",$ARGV[0]) or die; print $f $s->sockport,"\n"; close $f;
  alarm 300; my @h; while (my $c=$s->accept) { push @h,$c }' "$LAB/port" &
PIDS+=($!)
while [ ! -s "$LAB/port" ]; do sleep 0.1; done
cat > "$LAB/ssh.config" <<EOF
Host lab-host
  HostName 127.0.0.1
  Port $(cat "$LAB/port")
  StrictHostKeyChecking yes
  UserKnownHostsFile /dev/null
EOF
printf '#!/bin/bash\nexec ssh -F %s/ssh.config "$@"\n' "$LAB" > "$LAB/bin/ssh"
printf '#!/bin/bash\nexec ssh -F %s/ssh.config -G "$@"\n' "$LAB" > "$LAB/bin/ssh-G"
chmod +x "$LAB/bin/ssh" "$LAB/bin/ssh-G"
printf -- '- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)\n' > "$LAB/data/secondmates.md"
cat > "$LAB/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
CLEAN=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")

say "S1 fm-on.sh (this change) vs silent peer, FM_SSH_CONNECT_TIMEOUT=3"
t0=$(now)
"${CLEAN[@]}" FM_SSH_BIN="$LAB/bin/ssh" FM_SSH_CONNECT_TIMEOUT=3 perl -e 'alarm 40; exec @ARGV' \
  "$WT/bin/fm-on.sh" rsm1 fm-remote-secondmate-control.sh state rsm1 </dev/null; rc=$?
echo "rc=$rc elapsed=$(perl -e "printf '%.1f', $(now)-$t0")s"

say "S1-base fm-on.sh (base fba81cb) vs same silent peer, outer alarm 20s"
t0=$(now)
"${CLEAN[@]}" FM_SSH_BIN="$LAB/bin/ssh" perl -e 'alarm 20; exec @ARGV' \
  "$BASE/bin/fm-on.sh" rsm1 fm-remote-secondmate-control.sh state rsm1 </dev/null; rc=$?
echo "rc=$rc (142=killed by outer SIGALRM, i.e. still hanging) elapsed=$(perl -e "printf '%.1f', $(now)-$t0")s"

say "S2 effective OpenSSH options fm-on.sh passes (ssh -G on the real argv), default and override"
"${CLEAN[@]}" FM_SSH_BIN="$LAB/bin/ssh-G" "$WT/bin/fm-on.sh" rsm1 fm-remote-secondmate-control.sh state rsm1 </dev/null \
  | grep -E '^(batchmode|connecttimeout|serveraliveinterval|serveralivecountmax) '
echo "-- FM_SSH_CONNECT_TIMEOUT=7:"
"${CLEAN[@]}" FM_SSH_BIN="$LAB/bin/ssh-G" FM_SSH_CONNECT_TIMEOUT=7 "$WT/bin/fm-on.sh" rsm1 fm-remote-secondmate-control.sh state rsm1 </dev/null \
  | grep -E '^connecttimeout '
echo "-- base fba81cb for comparison:"
"${CLEAN[@]}" FM_SSH_BIN="$LAB/bin/ssh-G" "$BASE/bin/fm-on.sh" rsm1 fm-remote-secondmate-control.sh state rsm1 </dev/null \
  | grep -E '^(batchmode|connecttimeout) '

say "S3 invalid FM_SSH_CONNECT_TIMEOUT refused before ssh runs"
for bad in 0 soon -5; do
  printf '#!/bin/bash\necho SSH-LAUNCHED >&2\n' > "$LAB/bin/ssh-canary"; chmod +x "$LAB/bin/ssh-canary"
  "${CLEAN[@]}" FM_SSH_BIN="$LAB/bin/ssh-canary" FM_SSH_CONNECT_TIMEOUT=$bad "$WT/bin/fm-on.sh" rsm1 fm-remote-secondmate-control.sh state rsm1 </dev/null
  echo "FM_SSH_CONNECT_TIMEOUT=$bad -> rc=$?"
done

say "S4 liveness probe through real ssh held past connect (ConnectTimeout=120), FM_SECONDMATE_PROBE_TIMEOUT=3"
cp "$LAB/state/rsm1.meta" "$LAB/meta.before"
t0=$(now)
"${CLEAN[@]}" STATE="$LAB/state" FM_SSH_BIN="$LAB/bin/ssh" FM_SSH_CONNECT_TIMEOUT=120 FM_SECONDMATE_PROBE_TIMEOUT=3 \
  /bin/bash -c '. "$0/bin/fm-secondmate-liveness-lib.sh"; for m in poll full; do fm_secondmate_liveness_probe "$1" rsm1 $m;
    printf "mode=%s status=%s state=%s kill=%s reason=%s\n" $m "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" "$FM_SM_LIVE_REASON"; done' \
  "$WT" "$LAB/state/rsm1.meta"
echo "elapsed for both probes=$(perl -e "printf '%.1f', $(now)-$t0")s"
cmp -s "$LAB/meta.before" "$LAB/state/rsm1.meta" && echo "route meta unchanged: yes" || echo "route meta unchanged: NO"

say "S5 watcher stalled inside a real remote probe (real ssh, ConnectTimeout=120, probe timeout 120) is evicted by a re-arm"
W="$WT/bin/fm-watch.sh"
WENV=("${CLEAN[@]}" FM_SSH_BIN="$LAB/bin/ssh" FM_SSH_CONNECT_TIMEOUT=120 FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999)
"${WENV[@]}" FM_SECONDMATE_LIVENESS_SECS=1 FM_SECONDMATE_PROBE_TIMEOUT=120 "$W" > "$LAB/holder.out" 2>&1 &
HOLDER=$!; PIDS+=($HOLDER)
for i in $(seq 1 300); do pgrep -f "ssh -F $LAB/ssh.config" >/dev/null && break; sleep 0.1; done
echo "holder watcher pid=$HOLDER; lock pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null); ssh in flight: $(pgrep -f "ssh -F $LAB/ssh.config" | tr '\n' ' ')"
sleep 1
touch -t 200001010000 "$LAB/state/.last-watcher-beat"   # beacon as after a long sleep
t0=$(now)
"${WENV[@]}" FM_WATCHER_STALL_BOUND=3 FM_SECONDMATE_LIVENESS_SECS=999999 "$W" > "$LAB/arm2.out" 2> "$LAB/arm2.err" &
ARM2=$!; PIDS+=($ARM2)
for i in $(seq 1 150); do [ "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)" = "$ARM2" ] && break; kill -0 $ARM2 2>/dev/null || break; sleep 0.1; done
echo "after re-arm: lock pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null) (arm2=$ARM2) elapsed=$(perl -e "printf '%.1f', $(now)-$t0")s"
kill -0 $HOLDER 2>/dev/null && echo "holder alive: YES" || echo "holder alive: no (evicted)"
sleep 1; echo "arm2 stdout:"; grep -E '^watcher:' "$LAB/arm2.out"; echo "arm2 stderr:"; cat "$LAB/arm2.err"

say "S6 adversarial: a third arm against healthy arm2 with a stale-but-under-hard-bound beacon is NOT told it sent TERM"
touch -t "$(date -v-40S +%Y%m%d%H%M.%S)" "$LAB/state/.last-watcher-beat"
"${WENV[@]}" FM_WATCHER_STALL_BOUND=999999 FM_WATCHER_STALE_GRACE=5 "$W" > "$LAB/arm3.out" 2> "$LAB/arm3.err"; echo "arm3 rc=$?"
cat "$LAB/arm3.err"
kill -0 $ARM2 2>/dev/null && echo "arm2 still alive and holding: $(cat "$LAB/state/.watch.lock/pid")"

say "S7 holder that survives its TERM gets the distinct sent-TERM refusal"
kill $ARM2; wait $ARM2 2>/dev/null
/bin/bash -c 'trap "" TERM; exec sleep 300' & STUB=$!; PIDS+=($STUB); sleep 0.2
ID=$(FM_STATE_OVERRIDE="$LAB/state" /bin/bash -c '. "$1"; fm_pid_identity "$2"' _ "$WT/bin/fm-wake-lib.sh" $STUB)
rm -rf "$LAB/state/.watch.lock"; mkdir -p "$LAB/state/.watch.lock"
printf '%s\n' $STUB > "$LAB/state/.watch.lock/pid"; printf '%s\n' "$LAB" > "$LAB/state/.watch.lock/fm-home"
printf '%s\n' "$W" > "$LAB/state/.watch.lock/watcher-path"; printf '%s\n' "$ID" > "$LAB/state/.watch.lock/pid-identity"
touch -t 200001010000 "$LAB/state/.last-watcher-beat"
"${WENV[@]}" FM_WATCHER_STALL_BOUND=3 "$W" > "$LAB/arm4.out" 2> "$LAB/arm4.err"; echo "arm4 rc=$?"; cat "$LAB/arm4.err"
kill -KILL $STUB 2>/dev/null
say "done; lab removed on exit"

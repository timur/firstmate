#!/usr/bin/env bash
# Live validation for fm/exit-readback-retry: real Claude Code in an isolated
# fm-lab-* Herdr session, every herdr call routed through bin/fm-herdr-lab.sh.
# Run from the gate worktree: bash <this> <worktree-root>
set -u
ROOT=$1
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name exit-readback)
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-exit-readback.XXXXXX")
FAKEBIN=$TMP/fakebin; mkdir -p "$FAKEBIN"
RESULT=0
say() { printf '\n=== %s\n' "$*"; }
ok() { printf 'PASS - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*"; RESULT=1; }
cleanup() {
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || RESULT=1
  rm -rf "$TMP"
  echo "teardown done; result=$RESULT"
  exit "$RESULT"
}
trap cleanup EXIT

# herdr wrapper: strip any --session <SESSION> pair, refuse others, route via lab helper.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
out=(); seen=0
while [ \$# -gt 0 ]; do
  if [ "\$1" = --session ]; then
    [ "\${2:-}" = "$SESSION" ] || { echo "wrapper refused foreign session \${2:-}" >&2; exit 97; }
    seen=1; shift 2; continue
  fi
  out+=("\$1"); shift
done
case "\${out[0]:-}" in --version|version) exec env PATH="$ORIGINAL_PATH" herdr "\${out[@]}" ;; esac
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${out[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
"$LAB_HELPER" provision "$SESSION" || { bad "provision"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export HERDR_SESSION=$SESSION
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

LAB=$TMP/home
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { bad "lab home"; exit 1; }
mkdir -p "$LAB/data/exr"
printf '# Task\n## Captain'"'"'s intent\nlive exit test\n\n## Firstmate spec\nnone\n' > "$LAB/data/exr/brief.md"
PROJ=$TMP/proj; WT=$TMP/wt
git init -q "$PROJ"; printf x > "$PROJ/f"; git -C "$PROJ" add f
git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git -C "$PROJ" worktree add -q -b exr "$WT"

. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { bad "source herdr"; exit 1; }

launch_claude() {  # <pane>
  local pane=$1 i st
  lab pane run "$pane" "cd '$WT' && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
  for i in $(seq 1 60); do
    st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in
      idle|done) return 0 ;;
      blocked) case "$(lab pane read "$pane" --source visible 2>/dev/null)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$pane" down enter >/dev/null ;; esac ;;
    esac
    sleep 1
  done
  return 1
}

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || { bad container; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}; SEEDED=${CONTAINER_RAW#*$'\t'}
read -r TAB PANE <<<"$(fm_backend_herdr_create_task "$CONTAINER" fm-exr "$WT" "$SEEDED")"
TARGET="$SESSION:$PANE"
cat > "$LAB/state/exr.meta" <<EOF
window=$TARGET
endpoint_task_id=exr
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=${CONTAINER#*:}
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
echo "claude: $(PATH=$ORIGINAL_PATH claude --version | head -1); herdr: $(PATH=$ORIGINAL_PATH herdr --version | head -1); session=$SESSION target=$TARGET"
launch_claude "$PANE" || { bad "claude never idle"; lab pane read "$PANE" --source visible; exit 1; }
sleep 2

say "S-proof-delayed: /exit drawn ~1.0s after the first read-back (bounded re-read)"
# composer is empty; type /exit in the background after a delay, proof with 0.6s settle
( sleep 1.0; lab pane send-text "$PANE" "/exit" >/dev/null ) &
bg=$!
start=$(date +%s)
if fm_backend_herdr_payload_proof "$TARGET" "/exit" 12 0.6 2>"$TMP/p1.err"; then
  wait $bg; ok "payload_proof accepted a late-drawn /exit (styled='$FM_BACKEND_HERDR_PROOF_STYLED' plain='$FM_BACKEND_HERDR_PROOF_PLAIN'), no stderr: '$(cat "$TMP/p1.err")'"
else
  wait $bg; bad "payload_proof refused late-drawn /exit: $(cat "$TMP/p1.err")"
fi
fm_backend_herdr_composer_clear "$TARGET" "/exit" && ok "composer cleared back to empty (Ctrl+U), no Enter pressed" || bad "clear"
sleep 1
st=$(fm_backend_agent_state herdr "$TARGET"); echo "agent-state after clear: $st"
[ "$st" = running ] || bad "claude should still be running after the delayed-proof check, got $st"

say "S-proof-refuse-wrong: composer shows finished wrong text -> refuse after 1 read with escaped diagnostic"
lab pane send-text "$PANE" "hello there" >/dev/null; sleep 1
if fm_backend_herdr_payload_proof "$TARGET" "/exit" 12 0.6 2>"$TMP/p2.err"; then bad "proof accepted wrong text"
else cat "$TMP/p2.err"; grep -q "after 1 read(s)" "$TMP/p2.err" && ok "refused immediately (1 read) with diagnostic on stderr" || bad "expected 1 read"; fi
fm_backend_herdr_composer_clear "$TARGET" "hello there" || bad clear2
sleep 1

say "S-proof-refuse-absent: payload never drawn -> 3 bounded reads then diagnostic"
if fm_backend_herdr_payload_proof "$TARGET" "/exit" 12 0.4 2>"$TMP/p3.err"; then bad "proof accepted empty"
else cat "$TMP/p3.err"; grep -q "after 3 read(s)" "$TMP/p3.err" && ok "refused after the 3-read bound" || bad "expected 3 reads"; fi

say "S-exit-idle: fm-control exit on an idle real Claude"
run_control() { env FM_HOME="$LAB" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.3 "$ROOT/bin/fm-control.sh" "$@"; }
OUT=$(run_control exr exit 2>"$TMP/e1.err"); rc=$?
echo "rc=$rc stdout: $OUT"; echo "stderr: $(cat "$TMP/e1.err")"
case "$OUT" in "stopped exr"*) ok "idle exit stopped Claude";; *) bad "idle exit";; esac
echo "agent-state: $(fm_backend_agent_state herdr "$TARGET")"

say "S-exit-busy: fm-control exit on a busy real Claude (interrupt -> quiet composer -> /exit)"
launch_claude "$PANE" || { bad "claude relaunch never idle"; exit 1; }
sleep 2
fm_backend_herdr_send_text_submit "$TARGET" "Run the bash command: sleep 60 ; then say done." 3 0.4 0.6 >/dev/null
for i in $(seq 1 30); do [ "$(fm_backend_busy_state herdr "$TARGET" 2>/dev/null)" = busy ] && break; sleep 1; done
echo "busy-state before exit: $(fm_backend_busy_state herdr "$TARGET" 2>/dev/null)"
OUT=$(run_control exr exit 2>"$TMP/e2.err"); rc=$?
echo "rc=$rc stdout: $OUT"; echo "stderr: $(cat "$TMP/e2.err")"
case "$OUT" in "stopped exr"*) ok "busy exit interrupted then stopped Claude";; *) bad "busy exit"; lab pane read "$PANE" --source visible;; esac
echo "agent-state: $(fm_backend_agent_state herdr "$TARGET")"
lab pane read "$PANE" --source recent --lines 25 2>/dev/null | tail -25

#!/usr/bin/env bash
# Consultation status: a run counts as live only while its own brain-ask pid
# runs, and each Claude session sees only its own runs. Offline; fake runs.
#
#   tests/consult/run.sh
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/../.." && pwd)"

WORK="$(cd -P "$(mktemp -d)" && pwd)"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

export HOME="$WORK/home" BRAIN_STATE_DIR="$WORK/state" BRAIN_DATA_DIR="$WORK/data"
export BRAIN_CONFIG_DIR="$WORK/config" BRAIN_AUTH_DIR="$WORK/auth" BRAIN_ACCOUNT=default
unset BRAIN_ACCOUNT_FLAG CLAUDE_CODE_SESSION_ID
mkdir -p "$HOME" "$BRAIN_STATE_DIR/consult" "$BRAIN_DATA_DIR" "$BRAIN_CONFIG_DIR" "$BRAIN_AUTH_DIR"
# shellcheck source=../../host/lib/common.sh
. "$ROOT/host/lib/common.sh"
# Defined after the source: common.sh has an ok() of its own.
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1 [$2]"; fi; }
CONSULT="$BRAIN_STATE_DIR/consult"
OWNERS="$CONSULT/owners"

# A stand-in for a running consultation: a process whose argv[0] is brain-ask.
start_fake_run() { # $1=session $2=model ; prints pid
  local stamp; stamp="$(date +%s)"
  : >"$CONSULT/$2-$stamp.log"
  ( exec -a brain-ask sleep 30 ) >/dev/null 2>&1 &
  local pid=$!
  PIDS="$PIDS $pid"
  mkdir -p "$OWNERS"
  printf '%s\n%s\n%s\n%s\n' "$1" "$stamp" "$2" "$(_consult_process_start "$pid")" >"$OWNERS/$pid"
  printf '%s' "$pid"
}

echo "== a mention is not a run =="
( exec -a "grep brain-ask somefile" sleep 30 ) & PIDS="$PIDS $!"
: >"$CONSULT/grok-4.5-1000000000.log"
ln -sfn "$CONSULT/grok-4.5-1000000000.log" "$CONSULT/current"
check "a process naming brain-ask with no owner file is idle" '! consult_active'
check "brain consult status says idle"                       '[ "$(bash "$ROOT/host/bin/brain" consult status)" = idle ]'

echo "== session scoping =="
mine="$(start_fake_run session-a gpt-6.1-sol)"
check "own session sees its run"                 'consult_progress_line session-a | grep -q "^gpt-6.1-sol · thinking"'
check "another session does not"                 '! consult_active session-b'
check "a caller with no session id does not see a session's run" '! consult_active ""'
term="$(start_fake_run "" kimi-k3)"
check "a terminal run shows to callers with no session"  'consult_progress_line "" | grep -q "^kimi-k3"'
check "and not to a Claude session"                      '! consult_progress_line session-a | grep -q "^kimi-k3"'
kill "$term" 2>/dev/null
star="$(start_fake_run "*" luna-x)"
check "a run from a Claude Code build without session ids shows to every session" \
  'consult_progress_line session-z | grep -q "^luna-x"'
kill "$star" 2>/dev/null
rm -f "$OWNERS/$term" "$OWNERS/$star"
( exec -a "brain-ask reused" sleep 30 ) >/dev/null 2>&1 &
reused=$!; PIDS="$PIDS $reused"
printf 'session-r\n%s\nreuse-model\nMon Jan  1 00:00:00 2001\n' "$(date +%s)" >"$OWNERS/$reused"
: >"$CONSULT/reuse-model-$(date +%s).log"
touch -t 200001010000 "$CONSULT"/reuse-model-*.log
check "a reused pid that mentions brain-ask is not the run" '! consult_active session-r'
( exec -a "brain-ask old-format" sleep 30 ) >/dev/null 2>&1 &
oldfmt=$!; PIDS="$PIDS $oldfmt"
printf 'session-o\n%s\nold-model\n' "$(date +%s)" >"$OWNERS/$oldfmt"
: >"$CONSULT/old-model-$(date +%s).log"
check "an owner file from an older launcher still counts while its run lives" 'consult_active session-o'
touch -t 200001010000 "$OWNERS/$oldfmt" "$CONSULT"/old-model-*.log
check "but not once the old-format record is over an hour old" '! consult_active session-o'
kill "$oldfmt" 2>/dev/null
other="$(start_fake_run session-b muse-wonder-1.0)"
check "each session gets its own log"            'consult_progress_line session-b | grep -q "^muse-wonder-1.0"'
check "and the first session still gets its own" 'consult_progress_line session-a | grep -q "^gpt-6.1-sol"'
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

odd="$(start_fake_run session-l rec-model)"
: >"$CONSULT/rec-model-1000000000.7.log"
printf '%s\n' "$CONSULT/rec-model-1000000000.7.log" >>"$OWNERS/$odd"
check "the log the applet recorded wins over guessing" \
  '[ "$(consult_current_log session-l)" = "$CONSULT/rec-model-1000000000.7.log" ]'
kill "$odd" 2>/dev/null
rm -f "$OWNERS/$odd"

older="$(start_fake_run session-k gpt-council)"
sleep 1
newer="$(start_fake_run session-k grok-council)"
kill "$newer" 2>/dev/null
check "a running council member outranks one that just finished" \
  'consult_progress_line session-k | grep -q "^gpt-council"'
kill "$older" 2>/dev/null
rm -f "$OWNERS/$older" "$OWNERS/$newer"

( exec -a brain-ask sleep 30 ) >/dev/null 2>&1 &
nolog=$!; PIDS="$PIDS $nolog"
printf 'session-n\n%s\nslow-model\n%s\n' "$(date +%s)" "$(_consult_process_start "$nolog")" >"$OWNERS/$nolog"
check "a live run whose log is not created yet still counts" 'consult_active session-n'
check "and reads as thinking under its model name" \
  'consult_progress_line session-n | grep -q "^slow-model · thinking"'
kill "$nolog" 2>/dev/null; rm -f "$OWNERS/$nolog"

t0="$(date +%s)"
: >"$CONSULT/same-$t0.log"; : >"$CONSULT/same-$t0.1.log"
( exec -a brain-ask sleep 30 ) >/dev/null 2>&1 & s1=$!; PIDS="$PIDS $s1"
( exec -a brain-ask sleep 30 ) >/dev/null 2>&1 & s2=$!; PIDS="$PIDS $s2"
printf 'session-s1\n%s\nsame\n%s\n%s\n' "$t0" "$(_consult_process_start "$s1")" "$CONSULT/same-$t0.log" >"$OWNERS/$s1"
printf 'session-s2\n%s\nsame\n%s\n' "$t0" "$(_consult_process_start "$s2")" >"$OWNERS/$s2"
check "a guess never takes a log another owner recorded" \
  '[ "$(consult_current_log session-s2)" = "$CONSULT/same-$t0.1.log" ]'
kill "$s1" "$s2" 2>/dev/null; rm -f "$OWNERS/$s1" "$OWNERS/$s2"

t1="$(date +%s)"
: >"$CONSULT/m-other-$t1.log"
( exec -a brain-ask sleep 30 ) >/dev/null 2>&1 & mm=$!; PIDS="$PIDS $mm"
printf 'session-m\n%s\nm\n%s\n' "$t1" "$(_consult_process_start "$mm")" >"$OWNERS/$mm"
check "model m never takes another model's m-other log" \
  'consult_progress_line session-m | grep -q "^m · thinking"'
kill "$mm" 2>/dev/null; rm -f "$OWNERS/$mm"

quiet="$(start_fake_run session-q gpt-quiet)"
quiet_log="$(consult_current_log session-q)"
kill "$quiet" 2>/dev/null; wait "$quiet" 2>/dev/null
touch -t 200001010000 "$quiet_log"
printf 'still reasoning\n' >"$quiet_log.thinking"
check "a run that ends after only reasoning keeps its finish window" 'consult_active session-q'
rm -f "$OWNERS/$quiet"

echo "== finished runs =="
log_a="$(consult_current_log session-a)"
printf '## Findings\nnone\n' >"$log_a"
kill "$mine" 2>/dev/null; wait "$mine" 2>/dev/null
check "a run that just finished stays visible"   'consult_progress_line session-a | grep -q "writing: Findings"'
touch -t 200001010000 "$log_a"
printf '**Checking the take boundary**\n' >"$log_a.thinking"
check "the reasoning step reads without its asterisks" '[ "$(consult_thinking_step "$log_a")" = "Checking the take boundary" ]'
touch -t 200001010000 "$log_a.thinking"
check "a run that finished over 45 s ago is idle" '! consult_active session-a'
touch -t 200001010000 "$OWNERS/$mine"
consult_active session-a
check "its owner file is pruned 10 minutes after its last write" '[ ! -e "$OWNERS/$mine" ]'

long="$(start_fake_run session-a gpt-6.1-sol)"
touch -t 200001010000 "$OWNERS/$long"
kill "$long" 2>/dev/null
check "a run that took over 10 minutes still shows its finish" 'consult_active session-a'
gone="$(start_fake_run session-b muse-wonder-1.0)"
kill "$gone" 2>/dev/null
touch -t 200001010000 "$OWNERS/$gone" "$(ls "$CONSULT"/muse-wonder-1.0-*.log | tail -1)"
consult_active session-a
check "a session prunes another session's leftovers" '[ ! -e "$OWNERS/$gone" ]'
rm -f "$OWNERS/$long"

echo "== the launcher registers its run =="
mkdir -p "$BRAIN_DATA_DIR/native/current"
cat >"$BRAIN_DATA_DIR/native/current/brain-compress" <<'FAKE'
#!/bin/bash
: >"$BRAIN_STATE_DIR/consult/fake-model-$(date +%s).log"
sleep 25
FAKE
chmod +x "$BRAIN_DATA_DIR/native/current/brain-compress"
echo 0.9.0 >"$BRAIN_DATA_DIR/native/current/VERSION"
CLAUDE_CODE_SESSION_ID=session-c bash "$ROOT/host/bin/brain-ask" fake-model "hi" &
launched=$!; PIDS="$PIDS $launched"
sleep 1
check "owner file holds the launcher's pid and session" '[ "$(sed -n 1p "$OWNERS/$launched")" = session-c ]'
check "and the model, named as the log names it"        '[ "$(sed -n 3p "$OWNERS/$launched")" = fake-model ]'
check "the launched run is live for its session"        'consult_progress_line session-c | grep -q "^fake-model"'

echo "== brain consult wait =="
check "wait with nothing running says idle at once" \
  '[ "$(CLAUDE_CODE_SESSION_ID=session-z bash "$ROOT/host/bin/brain" consult wait 5)" = idle ]'
grow_log() { sleep 1; printf '## Draft\n' >>"$(consult_current_log session-c)"; }
grow_log &
export waited_from; waited_from="$(date +%s)"
check "wait returns when the run writes more" \
  'CLAUDE_CODE_SESSION_ID=session-c bash "$ROOT/host/bin/brain" consult wait 20 | grep -q "writing: Draft"'
check "and returns well before its limit" '[ $(( $(date +%s) - waited_from )) -lt 10 ]'
finished="$(start_fake_run session-f gpt-done)"
kill "$finished" 2>/dev/null; wait "$finished" 2>/dev/null
export waited_done; waited_done="$(date +%s)"
check "wait returns at once when the run has finished" \
  'CLAUDE_CODE_SESSION_ID=session-f bash "$ROOT/host/bin/brain" consult wait 30 >/dev/null; [ $(( $(date +%s) - waited_done )) -lt 4 ]'
start_fake_run session-w gpt-first >/dev/null
switch_run() { sleep 2; start_fake_run session-w gpt-second >/dev/null; }
switch_run &
export waited_switch; waited_switch="$(date +%s)"
check "wait returns when the session's current run changes" \
  'CLAUDE_CODE_SESSION_ID=session-w bash "$ROOT/host/bin/brain" consult wait 30 | grep -q "^gpt-second" && [ $(( $(date +%s) - waited_switch )) -lt 10 ]'
check "a non-number wait is refused" \
  '! CLAUDE_CODE_SESSION_ID=session-c bash "$ROOT/host/bin/brain" consult wait soon >/dev/null 2>&1'

echo "== hooks and statusline =="
hook_json() { printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"sleep 300"}}' "$1"; }
check "progress hook reports the session's own run" \
  'hook_json session-c | bash "$ROOT/host/claude/hooks/consult-progress.sh" | grep -q "fake-model"'
check "progress hook stays quiet for another session" \
  '[ -z "$(hook_json session-z | bash "$ROOT/host/claude/hooks/consult-progress.sh")" ]'
check "poll guard blocks a long wait in the owning session" \
  '! hook_json session-c | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null'
check "poll guard leaves other sessions alone" \
  'hook_json session-z | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null'
guard_cmd() { jq -nc --arg s session-c --arg c "$1" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}'; }
check "poll guard still blocks a real sleep loop" \
  '! guard_cmd "until done; do sleep 5; done" | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null'
export heredoc_cmd; heredoc_cmd="$(printf 'cat > fix.py <<%sEOF%s\nwhile True:\n    time.sleep 1\nEOF\npython3 fix.py' "'" "'")"
check "poll guard ignores loop words inside a heredoc body" \
  'guard_cmd "$heredoc_cmd" | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null'
check "but still judges the commands after the heredoc" \
  '! guard_cmd "$heredoc_cmd
sleep 120" | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null'
tab_cmd="$(printf 'cat <<-EOF > x\n\tsleep 1 inside\n\tEOF\nsleep 120')"
export tab_cmd
check "a <<- heredoc ends at its tab-indented terminator" \
  '! guard_cmd "$tab_cmd" | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null'
herestring_cmd="$(printf 'grep -q x <<<"$v"\nuntil done; do sleep 5; done')"
export herestring_cmd
check "a here-string is not a heredoc" \
  '! guard_cmd "$herestring_cmd" | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null'
guard_denies() { guard_cmd "$1" | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" >/dev/null 2>&1; [ "$?" -eq 2 ]; }
guard_allows() { guard_cmd "$1" | bash "$ROOT/host/claude/hooks/consult-poll-guard.sh" 2>/dev/null; }
export -f guard_denies guard_allows guard_cmd
check "a punctuated delimiter ends its heredoc" \
  "guard_denies \"\$(printf 'cat <<%sEND-X%s\\nEND-X\\nsleep 120' \"'\" \"'\")\""
check "a substitution inside an unquoted heredoc still counts" \
  "guard_denies \"\$(printf 'cat <<EOF\\n\$(sleep 120)\\nEOF')\""
check "a substitution spread over heredoc lines still counts" \
  "guard_denies \"\$(printf 'cat <<EOF\\n\$(\\nsleep 120\\n)\\nEOF')\""
check "a quoted heredoc body with a substitution is data" \
  "guard_allows \"\$(printf 'cat <<%sEOF%s\\n\$(sleep 120)\\nEOF' \"'\" \"'\")\""
check "quoted <<EOF text with no terminator does not hide a wait" \
  "guard_denies \"\$(printf 'echo \"<<EOF\"\\nuntil done; do sleep 5; done')\""
check "a heredoc marker inside a comment opens nothing" \
  "guard_denies \"\$(printf '# <<:\\nsleep 120\\n:')\""
check "two heredocs on one line are read in order" \
  "guard_denies \"\$(printf 'cat <<A <<%sB%s\\nA\\n<<:\\nB\\nsleep 120\\n:' \"'\" \"'\")\""
check "a partly quoted delimiter is literal data" \
  "guard_allows \"\$(printf 'cat <<E\"OF\"\\nwhile true; do sleep 1; done\\nEOF')\""
mkdir -p "$CONSULT"
printf '08\n%s\n' "$(consult_progress_line session-c 2>/dev/null)" >"$CONSULT/.last-progress-session-c"
check "a stamp of 08 does not fail the progress hook" \
  'hook_json session-c | bash "$ROOT/host/claude/hooks/consult-progress.sh" >/dev/null'
check "quoted <<EOF text with a later EOF line does not hide a wait" \
  "guard_denies \"\$(printf 'echo \"<<EOF\"\\nuntil done; do sleep 5; done\\nEOF')\""
check "a quoted delimiter still opens its heredoc" \
  "guard_allows \"\$(printf 'cat <<%sEOF%s\\nwhile true; do sleep 1; done\\nEOF' \"'\" \"'\")\""
check "a quoted body fed to a shell is judged as commands" \
  "guard_denies \"\$(printf 'bash <<%sEOF%s\\nwhile true; do sleep 1; done\\nEOF' \"'\" \"'\")\""
check "a quoted delimiter with a space ends at its own line" \
  "guard_allows \"\$(printf 'cat <<%sEND MARK%s\\nwhile true; do sleep 1; done\\nEND MARK' \"'\" \"'\")\""
check "a terminated quoted <<: in an echo hides nothing" \
  "guard_denies \"\$(printf 'echo %s<<:%s\\nsleep 120\\n:' \"'\" \"'\")\""
check "statusline shows the run for its session" \
  'printf "{\"session_id\":\"session-c\"}" | bash "$ROOT/host/claude/statusline.sh" | grep -q "fake-model"'
( exec -a brain-ask sleep 30 ) >/dev/null 2>&1 & pend=$!; PIDS="$PIDS $pend"
printf 'session-p\n%s\npend-model\n%s\n' "$(date +%s)" "$(_consult_process_start "$pend")" >"$OWNERS/$pend"
check "statusline survives a run whose log is not created yet" \
  'printf "{\"session_id\":\"session-p\"}" | bash "$ROOT/host/claude/statusline.sh" | grep -q "pend-model thinking"'
kill "$pend" 2>/dev/null; rm -f "$OWNERS/$pend"
printf 'session-z\n0812\nzero\nx\n' >"$OWNERS/99999"
check "a corrupt leading-zero start is dropped, not fatal" '! consult_active session-z && [ ! -e "$OWNERS/99999" ]'
check "statusline hides it from other sessions" \
  '! printf "{\"session_id\":\"session-z\"}" | bash "$ROOT/host/claude/statusline.sh" | grep -q "fake-model"'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# `brain attach` tests: list sessions across account sets, reopen one in the
# set it belongs to, refuse to double-open, hand over a headless one, and the
# cross-machine half (answering another brain's find/pull, and asking).
#
# Sandbox HOMEs; tmux and tailscale are stubs (tmux sessions are files, sent
# Taildrop files are copied to an outbox). No network, no services.
#
#   tests/attach/run.sh
# shellcheck disable=SC2034  # captured output is referenced inside check's eval
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
BRAIN="$REPO/host/bin/brain"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1 [$2]"; fi; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
PIDS=""
cleanup() { local p; for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/tmux" "$TMP/outbox"
LOG="$TMP/calls.log"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUB/$1"; chmod 755 "$STUB/$1"; }
stub tmux 'echo "tmux $*" >> "'"$LOG"'"
case "$1" in
  has-session) [ -e "'"$TMP"'/tmux/${3#=}" ] ;;
  new-session) shift; while [ $# -gt 0 ]; do [ "$1" = -s ] && { touch "'"$TMP"'/tmux/$2"; break; }; shift; done ;;
esac; exit $?'
stub tailscale 'case "$1 $2" in
  "status --json") printf "{\"Self\":{\"DNSName\":\"%s.tailnet.ts.net.\"}}\n" "${FAKE_HOST:-here}" ;;
  "file cp")
    if [ "${3:-}" = --targets ]; then printf "100.1.1.1\tfar\t\n100.1.1.2\tgone\toffline\n"; exit 0; fi
    shift 2; dest="${@: -1}"; mkdir -p "'"$TMP"'/outbox/${dest%:}"
    for f in "${@:1:$#-1}"; do cp "$f" "'"$TMP"'/outbox/${dest%:}/"; done
    echo "tailscale file cp $*" >> "'"$LOG"'" ;;
  "file get") shift 2; for a in "$@"; do d="$a"; done
    [ -d "${FAKE_INBOX:-/nonexistent}" ] && mv "$FAKE_INBOX"/* "$d"/ 2>/dev/null; exit 0 ;;
esac'
stub claude 'exit 0'
export PATH="$STUB:$PATH"

# conversation ID TITLE CWD CLAUDE_DIR — write a transcript where Claude would.
conversation() {
  local slug; slug="$(printf '%s' "$3" | sed 's|[^A-Za-z0-9]|-|g')"
  mkdir -p "$4/projects/$slug" "$3"
  { printf '{"type":"user","cwd":"%s","message":"hi"}\n' "$3"
    printf '{"type":"ai-title","aiTitle":"%s"}\n' "$2"; } > "$4/projects/$slug/$1.jsonl"
}
# record ID PID CLAUDE_DIR ENTRYPOINT [TMUX] — a live session record.
record() {
  mkdir -p "$3/sessions"
  jq -n --argjson pid "$2" --arg id "$1" --arg e "$4" --arg t "${5:-}" \
    '{pid: $pid, sessionId: $id, entrypoint: $e, tmux: (if $t == "" then null else $t end)}' > "$3/sessions/$2.json"
}
# live — start a stand-in process; its pid is in $LIVE (no subshell: a
# background job inside $( ) would hold the pipe open until it exits).
live() { sleep 300 >/dev/null 2>&1 & LIVE=$!; disown "$LIVE"; PIDS="$PIDS $LIVE"; }
run() { HOME="$H" "${BASH:-bash}" "$BRAIN" "$@" </dev/null 2>&1; }

H="$TMP/home"
mkdir -p "$H/.config/brain/accounts/work"; echo PORT=8318 > "$H/.config/brain/accounts/work/account"
W=11111111-aaaa-bbbb-cccc-000000000001   # work set, closed
P=22222222-aaaa-bbbb-cccc-000000000002   # default set, closed
T=33333333-aaaa-bbbb-cccc-000000000003   # running in a terminal
X=44444444-aaaa-bbbb-cccc-000000000004   # headless on a brain server
M=55555555-aaaa-bbbb-cccc-000000000005   # in tmux
conversation "$W" "Twilio call relay" "$H/work/relay" "$H/.claude-work"
conversation "$P" "Personal blog" "$H/blog" "$H/.claude"
conversation "$T" "Terminal thing" "$H/term" "$H/.claude"
conversation "$X" "Server thing" "$H/srv" "$H/.claude"
conversation "$M" "Tmux thing" "$H/tm" "$H/.claude"
# the same session teleported in from another folder: listed once
conversation "$P" "Personal blog" "$H/old-blog" "$H/.claude"; touch -t 202001010000 "$H/.claude/projects/"*old-blog*/"$P.jsonl"
live; TPID=$LIVE; record "$T" "$TPID" "$H/.claude" cli
live; XPID=$LIVE; record "$X" "$XPID" "$H/.claude" sdk-cli "brain-rc:@0.%0"
live; MPID=$LIVE; record "$M" "$MPID" "$H/.claude" cli "brain-teleport-55555555:@1.%1"

echo "== list =="
OUT="$(run attach)"
check "lists sessions from every account set" \
  'printf %s "$OUT" | grep -q "Twilio call relay.*work" && printf %s "$OUT" | grep -q "Personal blog.*default"'
check "says what state each is in" \
  'printf %s "$OUT" | grep -q "Terminal thing.*open in a terminal" && printf %s "$OUT" | grep -q "Server thing.*running on a brain server" && printf %s "$OUT" | grep -q "Tmux thing.*running (tmux brain-teleport-55555555)" && printf %s "$OUT" | grep -q "Twilio call relay.*closed"'
check "a session with copies in two folders is listed once, newest" \
  '[ "$(printf %s "$OUT" | grep -c "Personal blog")" = 1 ] && printf %s "$OUT" | grep -q "$H/blog"'

echo "== open =="
: > "$LOG"
OUT="$(run attach twilio)"
check "a closed work-set session reopens under the work login" \
  'grep -q "new-session -d -s brain-open-11111111" "$LOG" && grep -q "BRAIN_ACCOUNT=work CLAUDE_CONFIG_DIR=$H/.claude-work" "$LOG"'
check "in its own directory, resumed with Remote Control" \
  'tr -d "\\\\" < "$LOG" | grep -q "cd $H/work/relay" && tr -d "\\\\" < "$LOG" | grep -qF -- "--resume $W --remote-control Twilio call relay"'
check "trusted in the work set's config" 'jq -e --arg d "$H/work/relay" ".projects[\$d]" "$H/.claude-work/.claude.json" >/dev/null'
check "without a terminal, says how to attach" 'printf %s "$OUT" | grep -q "tmux attach -t brain-open-11111111"'
: > "$LOG"; run attach twilio >/dev/null
check "a second attach reuses it instead of starting another" '! grep -q new-session "$LOG"'
OUT="$(run attach 222)"
check "an id prefix works too" 'printf %s "$OUT" | grep -q "resumed \"Personal blog\" (account set default)"'

echo "== refuse, hand over =="
OUT="$(run attach thing)"
check "ambiguous words list the candidates" \
  'printf %s "$OUT" | grep -q "matches 3 sessions" && printf %s "$OUT" | grep -q "33333333"'
OUT="$(run attach terminal thing)"
check "one open in another terminal is refused" \
  'printf %s "$OUT" | grep -q "open in a terminal already (pid $TPID" && kill -0 "$TPID"'
OUT="$(run attach tmux thing)"
check "one in tmux is attached, not restarted" 'printf %s "$OUT" | grep -q "tmux attach -t brain-teleport-55555555"'
OUT="$(run attach server thing)"
check "a headless one is not touched without a yes" \
  'printf %s "$OUT" | grep -q "rerun with --yes" && kill -0 "$XPID"'
: > "$LOG"; OUT="$(run attach server thing --yes)"
check "with --yes it is ended and reopened here" \
  '! kill -0 "$XPID" 2>/dev/null && grep -q "new-session -d -s brain-open-44444444" "$LOG"'

echo "== another brain asks (this brain answers) =="
IN="$TMP/inbox"; mkdir -p "$IN"
echo '{"kind":"find","from":"asker","nonce":"n1","query":"twilio"}' > "$IN/brain-teleport-find-n1.json"
HOME="$H" FAKE_INBOX="$IN" FAKE_HOST=here "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
F="$TMP/outbox/asker/brain-teleport-found-n1.json"
check "a find gets an answer with the match and its state" \
  '[ -f "$F" ] && [ "$(jq -r ".sessions[0].id" "$F")" = "$W" ] && [ "$(jq -r ".sessions[0].state" "$F")" = closed ] && [ "$(jq -r .host "$F")" = here ]'
echo '{"kind":"pull","from":"asker","nonce":"n2","id":"'"$W"'","end":false}' > "$IN/brain-teleport-pull-n2.json"
HOME="$H" FAKE_INBOX="$IN" FAKE_HOST=here "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
check "a pull sends the session over" '[ -f "$TMP/outbox/asker/brain-teleport-$W.tgz" ]'
check "and remembers where it went" '[ "$(cut -d" " -f1 "$H/.local/state/brain/teleport/sent/$W")" = asker ]'
echo '{"kind":"pull","from":"asker","nonce":"n3","id":"'"$T"'","end":false}' > "$IN/brain-teleport-pull-n3.json"
HOME="$H" FAKE_INBOX="$IN" "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
check "a running one isn't taken unless the asker said to end it" \
  '[ ! -f "$TMP/outbox/asker/brain-teleport-$T.tgz" ] && kill -0 "$TPID" && grep -q "running here" "$H/.local/state/brain/teleport/log"'
echo '{"kind":"find","from":"bad host;rm","nonce":"n4","query":"x"}' > "$IN/brain-teleport-find-n4.json"
HOME="$H" FAKE_INBOX="$IN" "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
check "a request with a malformed sender is ignored" '[ ! -d "$TMP/outbox/bad host;rm" ] && grep -q "bad sender" "$H/.local/state/brain/teleport/log"'

echo "== this brain asks =="
OUT="$(BRAIN_ATTACH_WAIT=2 run attach twilio)"
check "a session teleported away asks the machine it went to" \
  'printf %s "$OUT" | grep -q "was teleported to asker" && [ -f "$TMP/outbox/asker/"brain-teleport-find-*.json ]'
H2="$TMP/home2"; IN2="$TMP/inbox2"; mkdir -p "$H2" "$IN2"
jq -n --arg id "$X" '{host: "far", nonce: "q1", sessions: [{id: $id, title: "Server thing", cwd: "/srv", set: "work", state: "closed", mtime: 1}]}' \
  > "$IN2/brain-teleport-found-q1.json"
OUT="$(HOME="$H2" FAKE_INBOX="$IN2" BRAIN_ATTACH_NONCE=q1 BRAIN_ATTACH_WAIT=3 BRAIN_ATTACH_LAND_WAIT=1 \
  "${BASH:-bash}" "$BRAIN" attach server thing </dev/null 2>&1)"
check "not here: it asks the online brains and offers to bring it over" \
  'printf %s "$OUT" | grep -q "asking far for" && printf %s "$OUT" | grep -q "is on far (closed there, in /srv). Bring it over here?" && [ ! -d "$TMP/outbox/gone" ]'
OUT="$(HOME="$H2" FAKE_INBOX="$IN2" BRAIN_ATTACH_NONCE=q2 BRAIN_ATTACH_WAIT=3 BRAIN_ATTACH_LAND_WAIT=1 \
  "${BASH:-bash}" "$BRAIN" attach server thing --yes </dev/null 2>&1)"
check "no answer is reported, not hung on" 'printf %s "$OUT" | grep -q "didn.t answer"'
jq -n --arg id "$X" '{host: "far", nonce: "q3", sessions: [{id: $id, title: "Server thing", cwd: "/srv", set: "work", state: "headless:99", mtime: 1}]}' \
  > "$IN2/brain-teleport-found-q3.json"
rm -rf "$TMP/outbox/far"
OUT="$(HOME="$H2" FAKE_INBOX="$IN2" BRAIN_ATTACH_NONCE=q3 BRAIN_ATTACH_WAIT=3 BRAIN_ATTACH_LAND_WAIT=1 \
  "${BASH:-bash}" "$BRAIN" attach server thing --yes </dev/null 2>&1)"
check "running there: with --yes it asks for it, ending the copy there" \
  '[ "$(jq -r .end "$TMP/outbox/far/brain-teleport-pull-q3.json")" = true ] && [ "$(jq -r .id "$TMP/outbox/far/brain-teleport-pull-q3.json")" = "$X" ]'
check "and says when it hasn't landed yet" 'printf %s "$OUT" | grep -q "it will land on its own"'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

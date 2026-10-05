#!/usr/bin/env bash
# Teleport tests: pack a session on one "machine", land it on another, and
# check the code state, the conversation and the receipt all arrive intact —
# and that the source checkout is never touched.
#
# Two sandbox HOMEs stand in for the two brains. tailscale, tmux and claude
# are stubs; git is real. No network, no services.
#
#   tests/teleport/run.sh
# shellcheck disable=SC2034  # captured output is referenced inside check's eval
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
BRAIN="$REPO/host/bin/brain"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1 [$2]"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUB/$1"; chmod 755 "$STUB/$1"; }
LOG="$TMP/calls.log"
stub tailscale 'case "$1 $2" in
  "status --json") printf "{\"Self\":{\"HostName\":\"Display-Name\",\"DNSName\":\"%s.tailnet.ts.net.\"}}\n" "${FAKE_HOST:-host}" ;;
  "file cp") echo "tailscale $*" >> "'"$LOG"'" ;;
  "file get") shift 2; for a in "$@"; do d="$a"; done
              [ -d "${FAKE_INBOX:-/nonexistent}" ] && mv "$FAKE_INBOX"/* "$d"/ 2>/dev/null; exit 0 ;;
esac'
stub tmux 'echo "tmux $*" >> "'"$LOG"'"'
stub claude 'exit 0'
export PATH="$STUB:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

ID=11111111-2222-3333-4444-555555555555
SRC="$TMP/src"; DST="$TMP/dst"; ORIGIN="$TMP/origin.git"
mkdir -p "$SRC" "$DST"
git init -q --bare "$ORIGIN"

# --- the source machine: a repo with every kind of in-flight work
WORK="$SRC/code/proj"
git clone -q "$ORIGIN" "$WORK" 2>/dev/null
mkdir -p "$WORK/app"
echo one > "$WORK/app/keep.txt"; echo gone > "$WORK/app/delete-me.txt"; echo v1 > "$WORK/app/edit.txt"
git -C "$WORK" add -A && git -C "$WORK" commit -qm base && git -C "$WORK" push -q origin main 2>/dev/null
git -C "$WORK" checkout -qb feature
echo unpushed > "$WORK/app/unpushed.txt"
git -C "$WORK" add -A && git -C "$WORK" commit -qm unpushed
UNPUSHED="$(git -C "$WORK" rev-parse HEAD)"
echo v2 > "$WORK/app/edit.txt"; git -C "$WORK" add app/edit.txt  # staged
echo v3 > "$WORK/app/edit.txt"                                     # and edited again
rm "$WORK/app/delete-me.txt"
echo fresh > "$WORK/app/untracked.txt"
STATUS_BEFORE="$(git -C "$WORK" status --porcelain)"; INDEX_BEFORE="$(git -C "$WORK" diff --cached)"

# the conversation, started in app/
SLUG="$(printf '%s' "$WORK/app" | sed 's|[^A-Za-z0-9]|-|g')"
mkdir -p "$SRC/.claude/projects/$SLUG/$ID/subagents" "$SRC/.claude/sessions"
{ printf '{"type":"user","cwd":"%s","message":"remember pineapple"}\n' "$WORK/app"
  printf '{"type":"assistant","message":"OK"}\n'
  printf '{"type":"user","cwd":"%s","message":"in a subdir"}\n' "$WORK/app/deeper"
  printf '{"type":"user","cwd":"/elsewhere","message":"untouched"}\n'
} > "$SRC/.claude/projects/$SLUG/$ID.jsonl"
echo '{}' > "$SRC/.claude/projects/$SLUG/$ID/subagents/a.jsonl"
printf '{"pid":1,"sessionId":"%s","name":"core-pineapple"}\n' "$ID" > "$SRC/.claude/sessions/1.json"

echo "== pack =="
OUT="$TMP/out"; mkdir -p "$OUT"
HOME="$SRC" FAKE_HOST=src-host "${BASH:-bash}" "$BRAIN" teleport _pack "$ID" "$OUT"
PKG="$OUT/brain-teleport-$ID.tgz"
check "package written" '[ -f "$PKG" ]'
mkdir -p "$TMP/peek"; tar xzf "$PKG" -C "$TMP/peek"
check "carries manifest, conversation, subagents and bundle" \
  '[ -f "$TMP/peek/manifest.json" ] && [ -f "$TMP/peek/transcript.jsonl" ] && [ -f "$TMP/peek/session-dir/subagents/a.jsonl" ] && [ -f "$TMP/peek/repo.bundle" ]'
eq "records where the session started" "/app" "$(jq -r .rel "$TMP/peek/manifest.json")"
eq "records the branch" feature "$(jq -r .branch "$TMP/peek/manifest.json")"
eq "records the sender" src-host "$(jq -r .from "$TMP/peek/manifest.json")"
eq "names it after the session" core-pineapple "$(jq -r .name "$TMP/peek/manifest.json")"
eq "source working tree untouched" "$STATUS_BEFORE" "$(git -C "$WORK" status --porcelain)"
eq "source index untouched" "$INDEX_BEFORE" "$(git -C "$WORK" diff --cached)"
check "no temporary refs left behind" '[ -z "$(git -C "$WORK" for-each-ref refs/brain-teleport)" ]'

echo "== land =="
git clone -q "$ORIGIN" "$DST/repos/proj" 2>/dev/null   # the target only has what was pushed
# the landed session registering with Remote Control
mkdir -p "$DST/.claude/sessions"
printf '{"pid":2,"sessionId":"%s","bridgeSessionId":"session_01LANDED"}\n' "$ID" > "$DST/.claude/sessions/2.json"
: > "$LOG"
URL="$(HOME="$DST" FAKE_HOST=dst-host BRAIN_TELEPORT_WAIT=2 "${BASH:-bash}" "$BRAIN" teleport _land "$PKG")"
WT="$DST/repos/.teleport/proj-11111111"
check "worktree created" '[ -d "$WT/app" ]'
eq "unpushed commit arrived" "$UNPUSHED" "$(git -C "$WT" rev-parse HEAD)"
eq "branch recreated (it did not exist here)" feature "$(git -C "$WT" symbolic-ref --short HEAD)"
eq "uncommitted edit arrived" v3 "$(cat "$WT/app/edit.txt")"
check "deletion arrived" '[ ! -e "$WT/app/delete-me.txt" ]'
check "untracked file arrived, still untracked" \
  '[ "$(cat "$WT/app/untracked.txt")" = fresh ] && git -C "$WT" status --porcelain | grep -q "^?? app/untracked.txt"'
check "changes are uncommitted, not a commit" 'git -C "$WT" status --porcelain | grep -q "app/edit.txt"'
NEWCWD="$(cd -P "$WT/app" && pwd)"
NEWSLUG="$(printf '%s' "$NEWCWD" | sed 's|[^A-Za-z0-9]|-|g')"
T="$DST/.claude/projects/$NEWSLUG/$ID.jsonl"
check "conversation filed under the new directory" '[ -f "$T" ]'
eq "session cwd rewritten" "$NEWCWD" "$(jq -r 'select(.cwd) | .cwd' "$T" | head -1)"
eq "subdirectory cwd rewritten" "$NEWCWD/deeper" "$(jq -r 'select(.cwd) | .cwd' "$T" | sed -n 2p)"
eq "unrelated cwd left alone" /elsewhere "$(jq -r 'select(.cwd) | .cwd' "$T" | sed -n 3p)"
check "subagent transcripts filed too" '[ -f "$DST/.claude/projects/$NEWSLUG/$ID/subagents/a.jsonl" ]'
check "resumed with Remote Control in its own tmux session" \
  'grep -q "tmux new-session -d -s brain-teleport-11111111" "$LOG" && grep -qF -- "--resume\\ $ID\\ --remote-control\\ core-pineapple" "$LOG"'
check "default set: launched without another set's config dir" 'grep -q -- "-u CLAUDE_CONFIG_DIR BRAIN_ACCOUNT=default" "$LOG"'
eq "manifest names the account set" default "$(jq -r .account "$TMP/peek/manifest.json")"
check "directory pre-trusted" 'jq -e --arg d "$NEWCWD" ".projects[\$d].hasTrustDialogAccepted" "$DST/.claude.json" >/dev/null'
eq "prints the new link" "https://claude.ai/code/session_01LANDED" "$URL"
check "receipt sent back to the sender" 'grep -q "tailscale file cp .*brain-teleport-ack-$ID.json src-host:" "$LOG"'
check "no temporary refs left behind" '[ -z "$(git -C "$DST/repos/proj" for-each-ref refs/brain-teleport)" ]'

echo "== land: existing branch, clean pushed tree =="
git -C "$WORK" stash -q -u && git -C "$WORK" push -q origin feature 2>/dev/null
rm -f "$SRC/.claude/sessions/1.json"
OUT2="$TMP/out2"; mkdir -p "$OUT2"
HOME="$SRC" FAKE_HOST=src-host "${BASH:-bash}" "$BRAIN" teleport _pack "$ID" "$OUT2"
mkdir -p "$TMP/peek2"; tar xzf "$OUT2/brain-teleport-$ID.tgz" -C "$TMP/peek2"
check "nothing to bundle when clean and pushed" '[ ! -e "$TMP/peek2/repo.bundle" ]'
eq "falls back to the repo name" proj "$(jq -r .name "$TMP/peek2/manifest.json")"
DST2="$TMP/dst2"; git clone -q "$ORIGIN" "$DST2/repos/proj" 2>/dev/null
git -C "$DST2/repos/proj" branch -q feature origin/main   # someone's own branch by that name
HOME="$DST2" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" teleport _land "$OUT2/brain-teleport-$ID.tgz" >/dev/null
WT2="$DST2/repos/.teleport/proj-11111111"
eq "lands at the pushed commit" "$UNPUSHED" "$(git -C "$WT2" rev-parse HEAD)"
check "an existing local branch is never moved" \
  '[ "$(git -C "$DST2/repos/proj" rev-parse feature)" = "$(git -C "$DST2/repos/proj" rev-parse origin/main)" ] && ! git -C "$WT2" symbolic-ref -q HEAD >/dev/null'

echo "== outside a git repo: conversation only =="
NID=99999999-8888-7777-6666-555555555555
LOOSE="$SRC/notes"; mkdir -p "$LOOSE"
LSLUG="$(printf '%s' "$LOOSE" | sed 's|[^A-Za-z0-9]|-|g')"
mkdir -p "$SRC/.claude/projects/$LSLUG"
printf '{"type":"user","cwd":"%s","message":"remember mango"}\n' "$LOOSE" > "$SRC/.claude/projects/$LSLUG/$NID.jsonl"
OUT3="$TMP/out3"; mkdir -p "$OUT3"
WARN="$(HOME="$SRC" "${BASH:-bash}" "$BRAIN" teleport _pack "$NID" "$OUT3" 2>&1 >/dev/null)"
check "packs anyway, and says the files stay behind" \
  '[ -f "$OUT3/brain-teleport-$NID.tgz" ] && printf %s "$WARN" | grep -q "conversation only"'
DST4="$TMP/dst4"; : > "$LOG"
HOME="$DST4" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" teleport _land "$OUT3/brain-teleport-$NID.tgz" >/dev/null
LWT="$(cd -P "$DST4/repos/.teleport/notes-99999999" 2>/dev/null && pwd)"
check "lands in an empty directory" '[ -n "$LWT" ] && [ -z "$(ls -A "$LWT")" ]'
LNSLUG="$(printf '%s' "$LWT" | sed 's|[^A-Za-z0-9]|-|g')"
eq "conversation cwd rewritten" "$LWT" "$(jq -r .cwd "$DST4/.claude/projects/$LNSLUG/$NID.jsonl")"
check "resumed there" 'grep -qF -- "--resume\\ $NID" "$LOG"'

echo "== a long conversation =="
# Regression: `jq ... | head -1` died of SIGPIPE under pipefail on real-sized
# transcripts and the pack exited silently.
BID=77777777-6666-5555-4444-333333333333
{ printf '{"type":"user","cwd":"%s","message":"start"}\n' "$LOOSE"
  i=0; while [ $i -lt 20000 ]; do
    printf '{"type":"assistant","cwd":"%s","message":"%s"}\n' "$LOOSE" "padding padding padding padding padding $i"
    i=$((i+1)); done
} > "$SRC/.claude/projects/$LSLUG/$BID.jsonl"
OUT4="$TMP/out4"; mkdir -p "$OUT4"
HOME="$SRC" "${BASH:-bash}" "$BRAIN" teleport _pack "$BID" "$OUT4" >/dev/null 2>&1
check "packs a 20k-line conversation" '[ -f "$OUT4/brain-teleport-$BID.tgz" ]'

echo "== desktop Taildrop: files saved straight to ~/Downloads =="
# The Linux systray and macOS apps save Taildrop files to Downloads instead of
# holding them for `tailscale file get` — the receiver must look there too.
DD="$TMP/dstd"; git clone -q "$ORIGIN" "$DD/repos/proj" 2>/dev/null
mkdir -p "$DD/Downloads"
cp "$OUT2/brain-teleport-$ID.tgz" "$DD/Downloads/"
echo '{"id":"x"}' > "$DD/Downloads/brain-teleport-ack-x.json"
echo mine > "$DD/Downloads/brain-teleport-notes.txt"
echo mine > "$DD/Downloads/report.pdf"
HOME="$DD" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
check "a package saved to Downloads is landed" \
  '[ -d "$DD/repos/.teleport/proj-11111111" ] && [ -f "$DD/.local/state/brain/teleport/done/brain-teleport-$ID.tgz" ] && [ ! -e "$DD/Downloads/brain-teleport-$ID.tgz" ]'
check "a receipt saved to Downloads is collected" '[ -f "$DD/.local/state/brain/teleport/acks/brain-teleport-ack-x.json" ]'
check "the user's own Downloads are left alone" \
  '[ -f "$DD/Downloads/report.pdf" ] && [ -f "$DD/Downloads/brain-teleport-notes.txt" ]'

echo "== account sets =="
# A session in the "work" set lives in ~/.claude-work and must land there,
# under the work login — never in another set's.
WID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
mkdir -p "$SRC/.claude-work/projects/$SLUG" "$SRC/.claude-work/sessions"
printf '{"type":"user","cwd":"%s","message":"work stuff"}\n' "$WORK/app" > "$SRC/.claude-work/projects/$SLUG/$WID.jsonl"
printf '{"pid":3,"sessionId":"%s","name":"work-session"}\n' "$WID" > "$SRC/.claude-work/sessions/3.json"
OUTW="$TMP/outw"; mkdir -p "$OUTW"
# run from the default set (a plain terminal), by id
HOME="$SRC" "${BASH:-bash}" "$BRAIN" teleport _pack "$WID" "$OUTW" >/dev/null 2>&1
PKGW="$OUTW/brain-teleport-$WID.tgz"
eq "a work session is packed as work" work "$(tar xzf "$PKGW" -O ./manifest.json | jq -r .account)"
eq "and named from the work set's records" work-session "$(tar xzf "$PKGW" -O ./manifest.json | jq -r .name)"

DW="$TMP/dstw"; git clone -q "$ORIGIN" "$DW/repos/proj" 2>/dev/null
: > "$LOG"
check "refused where there is no work set" \
  '! HOME="$DW" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" teleport _land "$PKGW" >/dev/null 2>&1'
check "nothing built or started when refused" \
  '[ ! -e "$DW/repos/.teleport/proj-aaaaaaaa" ] && ! grep -q new-session "$LOG"'
check "nothing filed in the default set" '[ -z "$(ls "$DW/.claude/projects" 2>/dev/null)" ]'

mkdir -p "$DW/.config/brain/accounts/work" "$DW/.claude-work/sessions"
echo PORT=8318 > "$DW/.config/brain/accounts/work/account"
printf '{"pid":4,"sessionId":"%s","bridgeSessionId":"session_01WORK"}\n' "$WID" > "$DW/.claude-work/sessions/4.json"
URLW="$(HOME="$DW" BRAIN_TELEPORT_WAIT=2 "${BASH:-bash}" "$BRAIN" teleport _land "$PKGW")"
WWT="$(cd -P "$DW/repos/.teleport/proj-aaaaaaaa/app" && pwd)"
WSLUG="$(printf '%s' "$WWT" | sed 's|[^A-Za-z0-9]|-|g')"
check "filed in the work set's Claude dir" '[ -f "$DW/.claude-work/projects/$WSLUG/$WID.jsonl" ]'
check "not in the default set's" '[ ! -e "$DW/.claude/projects/$WSLUG" ]'
check "trusted in the work set's .claude.json" \
  'jq -e --arg d "$WWT" ".projects[\$d].hasTrustDialogAccepted" "$DW/.claude-work/.claude.json" >/dev/null && [ ! -e "$DW/.claude.json" ]'
check "started with the work login" \
  'grep -q "BRAIN_ACCOUNT=work CLAUDE_CONFIG_DIR=$DW/.claude-work" "$LOG" && grep -q "BRAIN_PROXY_URL=http://127.0.0.1:8318" "$LOG"'
eq "link read from the work set's sessions" "https://claude.ai/code/session_01WORK" "$URLW"
check "receipt names the set" 'grep -q "landed $WID .*(account set work)" "$DW/.local/state/brain/teleport/log"'

# The target pins this repo to its "home" set: the pin wins over the sender's.
DP="$TMP/dstp"; git clone -q "$ORIGIN" "$DP/repos/proj" 2>/dev/null
mkdir -p "$DP/.config/brain/accounts/work" "$DP/.config/brain/accounts/home"
echo PORT=8318 > "$DP/.config/brain/accounts/work/account"; echo PORT=8319 > "$DP/.config/brain/accounts/home/account"
echo proj=home > "$DP/.config/brain/repo-accounts"
: > "$LOG"
HOME="$DP" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" teleport _land "$PKGW" >/dev/null 2>&1
check "a repo pinned on the target lands in its pinned set" \
  'grep -q "BRAIN_ACCOUNT=home CLAUDE_CONFIG_DIR=$DP/.claude-home" "$LOG" && [ -n "$(ls "$DP/.claude-home/projects")" ]'
check "and the override is logged" 'grep -q "pinned to account set home here" "$DP/.local/state/brain/teleport/log"'

echo "== account identity, not set name =="
# Seen live: on the Mac "default" is the work login; on Linux the work login
# is the set called "work" and "default" is personal. Landing must follow the
# login, not the name.
IID=12121212-3434-5656-7878-909090909090
IS="$TMP/srci"; mkdir -p "$IS"
git clone -q "$ORIGIN" "$IS/code/proj" 2>/dev/null
ISLUG="$(printf '%s' "$IS/code/proj" | sed 's|[^A-Za-z0-9]|-|g')"
mkdir -p "$IS/.claude/projects/$ISLUG"
echo '{"oauthAccount":{"accountUuid":"U-WORK","organizationUuid":"O-NAV","emailAddress":"me@work.example","organizationName":"Work"}}' > "$IS/.claude.json"
{ printf '{"type":"user","cwd":"%s","message":"hi"}\n' "$IS/code/proj"
  printf '{"type":"ai-title","aiTitle":"Early title"}\n'
  printf '{"type":"ai-title","aiTitle":"Fix the login page"}\n'
} > "$IS/.claude/projects/$ISLUG/$IID.jsonl"
OUTI="$TMP/outi"; mkdir -p "$OUTI"
HOME="$IS" FAKE_HOST=matts-mbp "${BASH:-bash}" "$BRAIN" teleport _pack "$IID" "$OUTI" >/dev/null 2>&1
PKGI="$OUTI/brain-teleport-$IID.tgz"
MI="$(tar xzf "$PKGI" -O ./manifest.json)"
eq "records who the session is signed in as" U-WORK/O-NAV "$(jq -r '.identity.account_uuid + "/" + .identity.org_uuid' <<<"$MI")"
check "and no secrets" '! printf %s "$MI" | grep -qiE "token|secret|refresh"'
eq "records the latest title" "Fix the login page" "$(jq -r .title <<<"$MI")"

DI="$TMP/dsti"; git clone -q "$ORIGIN" "$DI/repos/proj" 2>/dev/null
echo '{"oauthAccount":{"accountUuid":"U-PERSONAL","organizationUuid":"O-ME"}}' > "$DI/.claude.json"
mkdir -p "$DI/.config/brain/accounts/work" "$DI/.claude-work"
echo PORT=8318 > "$DI/.config/brain/accounts/work/account"
echo '{"oauthAccount":{"accountUuid":"U-WORK","organizationUuid":"O-NAV"}}' > "$DI/.claude-work/.claude.json"
: > "$LOG"
HOME="$DI" FAKE_HOST=mattvv-linux BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" teleport _land "$PKGI" >/dev/null 2>&1
check "a default-set session lands in the target set with the same login" \
  'grep -q "BRAIN_ACCOUNT=work CLAUDE_CONFIG_DIR=$DI/.claude-work" "$LOG" && [ -n "$(ls "$DI/.claude-work/projects")" ] && [ ! -d "$DI/.claude/projects" ]'
check "named after its title and where it came from" \
  'tr -d "\\\\" < "$LOG" | grep -qF -- "--remote-control Fix the login page (from matts-mbp)"'
check "opens with a recap turn" \
  'tr -d "\\\\" < "$LOG" | grep -qF "teleported from matts-mbp to mattvv-linux" && tr -d "\\\\" < "$LOG" | grep -qF "short recap"'

: > "$LOG"
HOME="$DI" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" teleport _land "$PKGI" >/dev/null 2>&1
check "the target set skips first-run setup (seen stuck at the theme picker)" \
  'jq -e ".hasCompletedOnboarding == true and .theme != null" "$DI/.claude-work/.claude.json" >/dev/null'
check "its own settings survive" 'jq -e ".oauthAccount.accountUuid == \"U-WORK\"" "$DI/.claude-work/.claude.json" >/dev/null'
check "alive but no link is reported stuck, not landed" \
  'grep -q "never reached claude.ai" "$DI/.local/state/brain/teleport/log" && ! grep -q "landed $IID" "$DI/.local/state/brain/teleport/log"'
check "teleporting the same session again replaces the old copy" \
  'grep -q "tmux kill-session -t =brain-teleport-12121212" "$LOG" && grep -q "new-session" "$LOG" && [ "$(ls -d "$DI"/repos/.teleport/proj-12121212* | wc -l | tr -d " ")" = 2 ]'

DN="$TMP/dstn"; git clone -q "$ORIGIN" "$DN/repos/proj" 2>/dev/null
echo '{"oauthAccount":{"accountUuid":"U-PERSONAL","organizationUuid":"O-ME"}}' > "$DN/.claude.json"
: > "$LOG"
check "refused when no set here has that login" \
  '! HOME="$DN" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" teleport _land "$PKGI" >/dev/null 2>&1'
check "nothing built or started" '[ ! -e "$DN/repos/.teleport/proj-12121212" ] && ! grep -q new-session "$LOG"'
check "the log names the login" 'grep -q "signed in as me@work.example" "$DN/.local/state/brain/teleport/log"'

echo "== retry after creating the set =="
DR="$TMP/dstr"; mkdir -p "$DR/inbox-src"; git clone -q "$ORIGIN" "$DR/repos/proj" 2>/dev/null
cp "$PKGW" "$DR/inbox-src/"
HOME="$DR" FAKE_INBOX="$DR/inbox-src" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
check "missing set: package kept in failed/" '[ -f "$DR/.local/state/brain/teleport/failed/brain-teleport-$WID.tgz" ]'
check "and the log says how to fix it" 'grep -q "brain account add work" "$DR/.local/state/brain/teleport/log"'
mkdir -p "$DR/.config/brain/accounts/work"; echo PORT=8318 > "$DR/.config/brain/accounts/work/account"
HOME="$DR" "${BASH:-bash}" "$BRAIN" teleport retry >/dev/null 2>&1
HOME="$DR" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
check "retry lands it in the new set" \
  '[ -f "$DR/.local/state/brain/teleport/done/brain-teleport-$WID.tgz" ] && [ -n "$(ls "$DR/.claude-work/projects")" ]'

echo "== receipts: only this send's, and only a running session =="
# Seen live: a re-teleport found the previous teleport's receipt and ended the
# original before the new copy had even landed.
DA="$TMP/dsta"; mkdir -p "$DA/.local/state/brain/teleport/acks"
AK="$DA/.local/state/brain/teleport/acks"
sleeper() { sleep 300 >/dev/null 2>&1 & echo $!; }
P1="$(sleeper)"
echo '{"id":"'"$ID"'","host":"old","nonce":"OLD","status":"ok"}' > "$AK/brain-teleport-ack-$ID.json"
echo '{"id":"'"$ID"'","host":"new","nonce":"N1","status":"ok"}' > "$AK/brain-teleport-ack-$ID (1).json"
HOME="$DA" "${BASH:-bash}" "$BRAIN" teleport _await "$ID" "$P1" N1 >/dev/null 2>&1
check "a stale receipt is ignored and the matching one ends the original" \
  '! kill -0 "$P1" 2>/dev/null && grep -q "confirmed on new" "$DA/.local/state/brain/teleport/log" && ! grep -q "confirmed on old" "$DA/.local/state/brain/teleport/log"'
P2="$(sleeper)"
echo '{"id":"'"$ID"'","host":"new","nonce":"N2","status":"failed"}' > "$AK/brain-teleport-ack-$ID.json"
HOME="$DA" "${BASH:-bash}" "$BRAIN" teleport _await "$ID" "$P2" N2 >/dev/null 2>&1
check "a failed landing keeps the original" 'kill -0 "$P2" 2>/dev/null && grep -q "did not come up on new (failed)" "$DA/.local/state/brain/teleport/log"'
kill "$P2" 2>/dev/null
check "receipts are consumed" '[ -z "$(ls "$AK")" ]'
check "the package carries the send's token" 'tar xzf "$PKG" -O ./manifest.json | jq -e "has(\"nonce\")" >/dev/null'

echo "== receive (the watchdog's half) =="
DST3="$TMP/dst3"; mkdir -p "$DST3/inbox-src"
git clone -q "$ORIGIN" "$DST3/repos/proj" 2>/dev/null
cp "$OUT2/brain-teleport-$ID.tgz" "$DST3/inbox-src/"
echo hi > "$DST3/inbox-src/holiday.jpg"
mkdir -p "$DST3/.claude/sessions"
printf '{"pid":9,"sessionId":"%s","bridgeSessionId":"session_01RECV"}\n' "$ID" > "$DST3/.claude/sessions/9.json"
HOME="$DST3" FAKE_INBOX="$DST3/inbox-src" BRAIN_TELEPORT_WAIT=1 "${BASH:-bash}" "$BRAIN" watchdog >/dev/null 2>&1
check "package landed and archived" \
  '[ -d "$DST3/repos/.teleport/proj-11111111" ] && [ -f "$DST3/.local/state/brain/teleport/done/brain-teleport-$ID.tgz" ]'
check "an ordinary Taildrop file goes to ~/Downloads" '[ -f "$DST3/Downloads/holiday.jpg" ]'
check "landing is logged" 'grep -q "landed $ID" "$DST3/.local/state/brain/teleport/log"'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

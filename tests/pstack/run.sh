#!/usr/bin/env bash
# pstack mode: `brain config pstack on|off` manages one CLAUDE.md block without
# touching the user's own text, and `brain verify` finds and runs the repo's
# verify skill. Runs against a sandbox HOME; no network.
#
#   tests/pstack/run.sh
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
BRAIN="$REPO/host/bin/brain"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1 [$2]"; fi; }
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
printf 'my own notes\n' > "$HOME/.claude/CLAUDE.md"
export MD="$HOME/.claude/CLAUDE.md"

echo "== brain config pstack =="
check "off by default"            '[ "$(bash "$BRAIN" config pstack)" = off ]'
bash "$BRAIN" config pstack on >/dev/null 2>&1
check "on installs the block"     'grep -q "<!-- claude-brain:pstack:start -->" "$MD"'
check "block inlines the brief"   'grep -q "Work verification-first" "$MD"'
check "full reference goes to a doc" 'grep -q "## Playbooks" "$HOME/.claude/docs/claude-brain/pstack.md"'
check "keeps the user text"       'grep -qx "my own notes" "$MD"'
check "reports on"                '[ "$(bash "$BRAIN" config pstack)" = on ]'
bash "$BRAIN" config pstack on >/dev/null 2>&1
check "re-running does not duplicate" '[ "$(grep -c "claude-brain:pstack:start" "$MD")" -eq 1 ]'
bash "$BRAIN" config pstack off >/dev/null 2>&1
check "off removes the block"     '! grep -q "claude-brain:pstack" "$MD"'
check "off removes the doc"       '[ ! -e "$HOME/.claude/docs/claude-brain/pstack.md" ]'
check "off keeps the user text"   'grep -qx "my own notes" "$MD"'
check "rejects other values"      '! bash "$BRAIN" config pstack maybe >/dev/null 2>&1'

echo "== brain verify =="
APP="$TMP/app"
mkdir -p "$APP" && git -C "$APP" init -q
check "fails without a verify skill" '! ( cd "$APP" && bash "$BRAIN" verify >/dev/null 2>&1 )'
mkdir -p "$APP/.claude/skills/verify-app/scripts"
printf '#!/usr/bin/env bash\necho "ran:$*"\n' > "$APP/.claude/skills/verify-app/scripts/verify.sh"
chmod +x "$APP/.claude/skills/verify-app/scripts/verify.sh"
check "defaults to doctor"        '[ "$(cd "$APP" && bash "$BRAIN" verify)" = "ran:doctor" ]'
check "passes args through"       '[ "$(cd "$APP" && bash "$BRAIN" verify tap --name go)" = "ran:tap --name go" ]'
mkdir -p "$APP/.claude/skills/verify-other/scripts"
cp "$APP/.claude/skills/verify-app/scripts/verify.sh" "$APP/.claude/skills/verify-other/scripts/verify.sh"
check "asks which when several"   '! ( cd "$APP" && bash "$BRAIN" verify >/dev/null 2>&1 )'
check "BRAIN_VERIFY_SKILL picks one" '[ "$(cd "$APP" && BRAIN_VERIFY_SKILL=verify-other bash "$BRAIN" verify snap)" = "ran:snap" ]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

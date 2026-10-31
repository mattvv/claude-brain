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
SK="$HOME/.claude/skills"
check "on installs the create skill"   '[ -f "$SK/brain-create-verify-skill/SKILL.md" ]'
check "no staging folders are left behind" '! ls -a "$SK" | grep -q "brain-stage"'
check "installed skills carry the marker" '[ -e "$SK/brain-council/.claude-brain" ]'
check "on installs the maintain skill" '[ -f "$SK/brain-maintain-verify-skill/SKILL.md" ]'
check "on installs the council skill"  '[ -f "$SK/brain-council/SKILL.md" ]'
mkdir -p "$SK/my-own-skill" && printf -- '---\nname: my-own-skill\n---\n' > "$SK/my-own-skill/SKILL.md"
mkdir -p "$SK/brain-old-renamed" && : > "$SK/brain-old-renamed/.claude-brain"
bash "$BRAIN" config pstack off >/dev/null 2>&1
check "off removes a marked skill a later release renamed" '[ ! -e "$SK/brain-old-renamed" ]'
check "off removes the block"     '! grep -q "claude-brain:pstack" "$MD"'
check "off removes shipped skills" '[ ! -e "$SK/brain-council" ] && [ ! -e "$SK/brain-create-verify-skill" ]'
check "off keeps the user's skills" '[ -f "$SK/my-own-skill/SKILL.md" ]'
mkdir -p "$SK/brain-council.brain-new" && printf 'backup\n' > "$SK/brain-council.brain-new/notes"
mkdir -p "$SK/brain-council" && printf 'mine\n' > "$SK/brain-council/SKILL.md"
bash "$BRAIN" config pstack on >/dev/null 2>&1
check "on keeps a user's skill that shares a shipped name" '[ "$(cat "$SK/brain-council/SKILL.md")" = mine ]'
bash "$BRAIN" config pstack off >/dev/null 2>&1
check "off does not remove it either"                     '[ "$(cat "$SK/brain-council/SKILL.md")" = mine ]'
check "a user folder named like a staging folder survives" '[ "$(cat "$SK/brain-council.brain-new/notes")" = backup ]'
rm -rf "$SK/brain-council.brain-new"
rm -rf "$SK/brain-council"
ln -s "$TMP/nowhere" "$SK/brain-council"
bash "$BRAIN" config pstack on >/dev/null 2>&1
check "on keeps a user's dangling link at a shipped name" '[ -L "$SK/brain-council" ] && [ ! -e "$SK/brain-council/.claude-brain" ]'
bash "$BRAIN" config pstack off >/dev/null 2>&1
rm -f "$SK/brain-council"
SHARED="$TMP/shared-skills"; mkdir -p "$SHARED/brain-council" && : > "$SHARED/brain-council/.claude-brain"
mv "$SK" "$SK.real" && ln -s "$SHARED" "$SK"
bash "$BRAIN" config pstack off >/dev/null 2>&1
check "a linked skills folder (another account's) is never touched" '[ -e "$SHARED/brain-council/.claude-brain" ]'
rm "$SK" && mv "$SK.real" "$SK"
check "off removes the doc"       '[ ! -e "$HOME/.claude/docs/claude-brain/pstack.md" ]'
check "off keeps the user text"   'grep -qx "my own notes" "$MD"'
check "rejects other values"      '! bash "$BRAIN" config pstack maybe >/dev/null 2>&1'

echo "== shipped skills are well formed =="
for dir in "$REPO"/host/claude/skills-pstack/*/; do
  name="$(basename "$dir")"
  check "$name: frontmatter name matches its folder" \
    '[ "$(sed -n "s/^name: *//p" "'"$dir"'SKILL.md" | head -1)" = "'"$name"'" ]'
  check "$name: has a description" 'grep -q "^description: ." "'"$dir"'SKILL.md"'
done

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

echo "== brain verify: Codex layout and --list =="
CODEX="$TMP/codex-app"
mkdir -p "$CODEX/.agents/skills/verify-web/scripts" "$CODEX/.agents/skills/verify-web/features"
git -C "$CODEX" init -q
printf '#!/usr/bin/env bash\necho "web:$*"\n' > "$CODEX/.agents/skills/verify-web/scripts/verify.sh"
chmod +x "$CODEX/.agents/skills/verify-web/scripts/verify.sh"
printf -- '---\nname: verify-web\ndescription: Drive the web app in a browser.\n---\n' > "$CODEX/.agents/skills/verify-web/SKILL.md"
printf '# Search notes\n' > "$CODEX/.agents/skills/verify-web/features/search.md"
printf '# Map index\n' > "$CODEX/.agents/skills/verify-web/features/README.md"
check "finds a skill under .agents/skills"   '[ "$(cd "$CODEX" && bash "$BRAIN" verify)" = "web:doctor" ]'
mkdir -p "$CODEX/.claude" && ln -s ../.agents/skills "$CODEX/.claude/skills"
check "a linked .claude/skills counts it once" '[ "$(cd "$CODEX" && bash "$BRAIN" verify snap)" = "web:snap" ]'
check "--list shows the skill and description" '(cd "$CODEX" && bash "$BRAIN" verify --list) | grep -q "verify-web.*Drive the web app"'
check "--list shows feature maps by title"     '(cd "$CODEX" && bash "$BRAIN" verify --list) | grep -q "search  *Search notes"'
check "--list leaves out the map README"       '! (cd "$CODEX" && bash "$BRAIN" verify --list) | grep -q "Map index"'
mkdir -p "$CODEX/.agents/skills/verify-api/scripts"
ln -s ../../verify-web/scripts/verify.sh "$CODEX/.agents/skills/verify-api/scripts/verify.sh"
check "two skills sharing one script are both listed" \
  '[ "$(cd "$CODEX" && bash "$BRAIN" verify --list 2>/dev/null | grep -c "^.*verify-")" -eq 2 ]'
rm -rf "$CODEX/.agents/skills/verify-api"
rm "$CODEX/.claude/skills"; mkdir -p "$CODEX/.claude/skills/verify-web/scripts"
printf '#!/usr/bin/env bash\necho "claude-web:$*"\n' > "$CODEX/.claude/skills/verify-web/scripts/verify.sh"
chmod +x "$CODEX/.claude/skills/verify-web/scripts/verify.sh"
check "on a name clash the .claude skill wins"   '[ "$(cd "$CODEX" && bash "$BRAIN" verify 2>/dev/null)" = "claude-web:doctor" ]'
check "and the clash is reported"                '(cd "$CODEX" && bash "$BRAIN" verify 2>&1 >/dev/null) | grep -q "skipping"'
mkdir -p "$CODEX/.agents/skills/verify-zzz/scripts"
printf '#!/usr/bin/env bash\necho "zzz:$*"\n' > "$CODEX/.agents/skills/verify-zzz/scripts/verify.sh"
chmod +x "$CODEX/.agents/skills/verify-zzz/scripts/verify.sh"
check "BRAIN_VERIFY_SKILL can pick the first of several" \
  '[ "$(cd "$CODEX" && BRAIN_VERIFY_SKILL=verify-web bash "$BRAIN" verify 2>/dev/null)" = "claude-web:doctor" ]'
check "an unknown BRAIN_VERIFY_SKILL fails"    '! (cd "$CODEX" && BRAIN_VERIFY_SKILL=verify-nope bash "$BRAIN" verify >/dev/null 2>&1)'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

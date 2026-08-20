#!/usr/bin/env bash
# Installer contract tests. Two things are being protected here:
#   1. --plan / --dry-run must describe exactly what would happen, and do nothing.
#   2. Installing onto a machine someone already uses must be a good guest:
#      back up their config once, never steal a statusline they already had,
#      never write to /etc on a local profile, and be fully reversible.
#
# Everything runs against a sandbox HOME. No network, no package installs, no
# services, no sudo.
#
#   tests/install/run.sh
# shellcheck disable=SC2034  # captured output is referenced inside check's eval
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1 [$2]"; fi; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT

echo "== install.sh --plan (changes nothing) =="
PLAN_HERE="$(bash "$REPO/install.sh" --plan --here --scope workspace --workspace /tmp/ws --link chatgpt,github --autostart 2>&1)"
check "plans the bootstrap step"   'printf %s "$PLAN_HERE" | grep -q "host/bootstrap.sh --profile local"'
check "plans the wiring step"      'printf %s "$PLAN_HERE" | grep -q "host/install.sh"'
check "passes the scope through"   'printf %s "$PLAN_HERE" | grep -q -- "--scope workspace --workspace /tmp/ws"'
check "passes the accounts through" 'printf %s "$PLAN_HERE" | grep -q -- "--link chatgpt,github"'
check "passes autostart through"   'printf %s "$PLAN_HERE" | grep -q -- "--autostart"'
check "says what it will install"  'printf %s "$PLAN_HERE" | grep -q "install dependencies"'

PLAN_SSH="$(bash "$REPO/install.sh" --plan --ssh me@box --scope machine 2>&1)"
check "ssh target re-runs the installer remotely" \
  'printf %s "$PLAN_SSH" | grep -q "ssh -t me@box" && printf %s "$PLAN_SSH" | grep -q -- "--here --scope machine"'

PLAN_DO="$(bash "$REPO/install.sh" --plan --digitalocean --region sfo3 --size s-2vcpu-4gb 2>&1)"
check "droplet plan uses doctl with the chosen region/size" \
  'printf %s "$PLAN_DO" | grep -q "doctl compute droplet create" && printf %s "$PLAN_DO" | grep -q "sfo3" && printf %s "$PLAN_DO" | grep -q "s-2vcpu-4gb"'

check "unknown flags are refused"  '! bash "$REPO/install.sh" --nonsense >/dev/null 2>&1'
check "--plan created nothing"     '[ ! -d /tmp/ws ]'

echo "== bootstrap.sh --dry-run (changes nothing) =="
DRY="$(bash "$REPO/host/bootstrap.sh" --dry-run --profile local 2>&1)"
check "names the target"           'printf %s "$DRY" | grep -q "target:"'
check "plans core tools"           'printf %s "$DRY" | grep -qE "(install|brew install).*(git|tmux|jq)"'
check "no droplet hardening on a local profile" \
  '! printf %s "$DRY" | grep -qE "ufw|enable-linger"'
DRY_DROPLET="$(bash "$REPO/host/bootstrap.sh" --dry-run --profile droplet 2>&1)"
check "droplet profile does harden" \
  'printf %s "$DRY_DROPLET" | grep -q "ufw" && printf %s "$DRY_DROPLET" | grep -q "enable-linger"'

echo "== host/install.sh is a good guest =="
# A personal machine that already has a statusline and a hook of its own.
H="$TMP/home"; mkdir -p "$H/.claude" "$H/.config/brain"
printf 'PROFILE=local\n' > "$H/.config/brain/settings"
cat > "$H/.claude/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"/Users/me/my-statusline.sh"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/Users/me/my-hook.sh"}]}]}}
JSON
OUT="$(HOME="$H" PATH="/usr/local/bin:/usr/bin:/bin" bash "$REPO/host/install.sh" 2>&1)"

check "keeps a statusline the user already had" \
  '[ "$(jq -r .statusLine.command "$H/.claude/settings.json")" = "/Users/me/my-statusline.sh" ]'
check "says how to switch to ours" 'printf %s "$OUT" | grep -q "brain config statusline on"'
check "leaves the user their own hooks" \
  'jq -r ".hooks.PreToolUse[].hooks[].command" "$H/.claude/settings.json" | grep -q "/Users/me/my-hook.sh"'
check "registers our hooks too" \
  'jq -r ".hooks.PreToolUse[].hooks[].command" "$H/.claude/settings.json" | grep -q "model-guard.sh"'
check "backs their settings up first" '[ -f "$H/.local/state/brain/settings.json.pre-brain" ]'
check "records a manifest of what it touched" '[ -s "$H/.local/state/brain/install-manifest" ]'
check "never writes /etc on a local profile" \
  '! grep -q motd "$H/.local/state/brain/install-manifest"'
check "links the commands" '[ -L "$H/.local/bin/brain" ]'

# Re-running must not bury the original backup.
HOME="$H" PATH="/usr/local/bin:/usr/bin:/bin" bash "$REPO/host/install.sh" >/dev/null 2>&1
check "re-running keeps the ORIGINAL backup" \
  '[ "$(jq -r .statusLine.command "$H/.local/state/brain/settings.json.pre-brain")" = "/Users/me/my-statusline.sh" ]'

# A fresh machine with no Claude config: the statusline is free, so take it.
H2="$TMP/fresh"; mkdir -p "$H2/.config/brain"
printf 'PROFILE=local\n' > "$H2/.config/brain/settings"
HOME="$H2" PATH="/usr/local/bin:/usr/bin:/bin" bash "$REPO/host/install.sh" >/dev/null 2>&1
check "claims an unset statusline" \
  '[ "$(jq -r .statusLine.command "$H2/.claude/settings.json")" = "$REPO/host/claude/statusline.sh" ]'

# A genuinely fresh machine: no settings file at all. This is the case the
# compat/update path hits, and a failing `sed` in an assignment under `set -e`
# used to kill the installer here without printing anything.
H3="$TMP/nosettings"; mkdir -p "$H3"
OUT3="$(HOME="$H3" PATH="/usr/local/bin:/usr/bin:/bin" bash "$REPO/host/install.sh" 2>&1)"
check "installs with no settings file at all" \
  'printf %s "$OUT3" | grep -q "claude-brain installed"'
check "and links the commands"  '[ -L "$H3/.local/bin/brain" ]'

# The compat symlink is what keeps `brain update` working for anyone installed
# before the rename: the OLD brain runs $REPO/droplet/install.sh after pulling.
H4="$TMP/viacompat"; mkdir -p "$H4"
OUT4="$(HOME="$H4" PATH="/usr/local/bin:/usr/bin:/bin" bash "$REPO/droplet/install.sh" 2>&1)"
check "the pre-rename path still installs" \
  'printf %s "$OUT4" | grep -q "claude-brain installed"'
check "and relinks into the new layout" \
  '[ "$(readlink "$H4/.local/bin/brain")" = "$REPO/host/bin/brain" ]'

echo "== ops instructions match the machine =="
# The block the brain reads must state the real scope and sudo situation.
HOME="$H2" bash "$REPO/host/bin/brain" config scope workspace "$H2/work" >/dev/null 2>&1
check "workspace scope confines the brain" \
  'grep -q "Stay in your workspace" "$H2/.claude/CLAUDE.md"'
check "workspace root is named in the block" 'grep -q "$H2/work" "$H2/.claude/CLAUDE.md"'
check "no unrendered placeholders"  '! grep -q "__[A-Z_]*__" "$H2/.claude/CLAUDE.md"'
HOME="$H2" bash "$REPO/host/bin/brain" config scope machine >/dev/null 2>&1
check "machine scope says so"       'grep -q "Scope: the whole machine" "$H2/.claude/CLAUDE.md"'
check "local block is the local one" 'grep -q "this is someone.s own computer" "$H2/.claude/CLAUDE.md"'

echo "== uninstall puts it back =="
printf 'y\n' | HOME="$H" bash "$REPO/host/bin/brain" uninstall >/dev/null 2>&1
check "hooks removed"        '[ "$(jq -r ".hooks.PreToolUse | length" "$H/.claude/settings.json")" = "0" ] || ! jq -r ".hooks.PreToolUse[].hooks[].command" "$H/.claude/settings.json" | grep -q model-guard'
check "their own statusline still theirs" \
  '[ "$(jq -r .statusLine.command "$H/.claude/settings.json")" = "/Users/me/my-statusline.sh" ]'
check "brain commands gone"  '[ ! -e "$H/.local/bin/brain" ]'
check "credentials kept without --purge" '[ -d "$H/.config/brain" ]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

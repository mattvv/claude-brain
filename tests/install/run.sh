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

# --ref installs a branch that is not merged yet (how a new platform gets
# tested before release). It has to reach the clone, the raw URL and the SSH
# re-run, or a branch install would pull half of main.
REFDIR="$TMP/refscript"; mkdir -p "$REFDIR"; cp "$REPO/install.sh" "$REFDIR/"
PLAN_REF="$(BRAIN_CLONE_DIR="$TMP/refclone" bash "$REFDIR/install.sh" --plan --here --ref somebranch 2>&1)"
check "clones the requested ref" \
  'printf %s "$PLAN_REF" | grep -q -- "clone --quiet --branch .somebranch."'
PLAN_REF_SSH="$(bash "$REPO/install.sh" --plan --ssh me@box --ref somebranch 2>&1)"
check "ssh re-run fetches and passes the ref" \
  'printf %s "$PLAN_REF_SSH" | grep -q "claude-brain/somebranch/install.sh" && printf %s "$PLAN_REF_SSH" | grep -q -- "--ref somebranch"'
PLAN_MAIN="$(BRAIN_CLONE_DIR="$TMP/refclone" bash "$REFDIR/install.sh" --plan --here 2>&1)"
check "defaults to main" 'printf %s "$PLAN_MAIN" | grep -q -- "clone --quiet --branch .main."'
check "--plan created nothing"     '[ ! -d /tmp/ws ]'

echo "== bootstrap.sh --dry-run (changes nothing) =="
DRY="$(bash "$REPO/host/bootstrap.sh" --dry-run --profile local 2>&1)"
check "names the target"           'printf %s "$DRY" | grep -q "target:"'
check "plans core tools"           'printf %s "$DRY" | grep -qE "(install|brew install).*(git|tmux|jq)"'
check "no droplet hardening on a local profile" \
  '! printf %s "$DRY" | grep -qE "ufw|enable-linger"'
DRY_DROPLET="$(bash "$REPO/host/bootstrap.sh" --dry-run --profile droplet 2>&1)"
if [ "$(uname -s)" = Linux ]; then
  check "droplet profile hardens on Linux" \
    'printf %s "$DRY_DROPLET" | grep -q "ufw" && printf %s "$DRY_DROPLET" | grep -q "enable-linger"'
else
  # There is no ufw or systemd here; a droplet profile on a Mac is a mistake,
  # not a target, and bootstrap must not pretend otherwise.
  check "droplet hardening is skipped off Linux" \
    '! printf %s "$DRY_DROPLET" | grep -qE "ufw|enable-linger"'
fi

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

echo "== ops block renders under a BSD awk =="
# macOS ships one-true-awk, which errors on a newline inside `awk -v` — that
# left a Mac with no ops instructions at all. On macOS this is just `awk`; on
# Linux it needs the original-awk package, so it is a no-op when absent.
OTA="$(command -v original-awk 2>/dev/null || true)"
[ "$(uname -s)" = Darwin ] && OTA="$(command -v awk)"
if [ -n "$OTA" ]; then
  SHIM="$TMP/awkshim"; mkdir -p "$SHIM"; ln -sf "$OTA" "$SHIM/awk"
  rm -f "$H2/.claude/CLAUDE.md"
  PATH="$SHIM:$PATH" HOME="$H2" bash "$REPO/host/bin/brain" config scope workspace "$H2/work" >/dev/null 2>&1
  check "ops block still lands"        'grep -q "Stay in your workspace" "$H2/.claude/CLAUDE.md"'
  check "and is fully rendered"        '! grep -q "__[A-Z_]*__" "$H2/.claude/CLAUDE.md"'
else
  printf '  \033[33mskip\033[0m one-true-awk not installed (apt install original-awk)\n'
fi

echo "== update notice =="
# Always-on brains start with no terminal, so the SessionStart hook and the
# statusline are how they hear about releases. A fresh checked_at (or a held
# lock) keeps the hook from spawning a background fetch against this checkout.
check "registers the update notice at session start" \
  'jq -r ".hooks.SessionStart[].hooks[].command" "$H/.claude/settings.json" | grep -q "update-notice.sh"'
UPD="$H/.local/state/brain/update"; mkdir -p "$UPD"
printf 'behind=2 latest=v9.9.9 checked_at=%s\n' "$(date +%s)" > "$UPD/available"
NOTICE="$(echo '{}' | HOME="$H" "$REPO/host/claude/hooks/update-notice.sh")"
check "tells the user when behind" \
  'printf %s "$NOTICE" | jq -e ".systemMessage | test(\"v9.9.9\") and test(\"brain update\")" >/dev/null'
check "tells the model to offer the update" \
  'printf %s "$NOTICE" | jq -e ".hookSpecificOutput.hookEventName == \"SessionStart\"" >/dev/null'
SL="$(echo '{"model":{"display_name":"m"},"cwd":"/x"}' | HOME="$H" bash "$REPO/host/claude/statusline.sh")"
check "statusline shows the update"  'printf %s "$SL" | grep -q "brain update v9.9.9"'
printf 'behind=0 latest=v9.9.9 checked_at=%s\n' "$(date +%s)" > "$UPD/available"
check "silent when up to date" \
  '[ -z "$(echo "{}" | HOME="$H" "$REPO/host/claude/hooks/update-notice.sh")" ]'
SL="$(echo '{"model":{"display_name":"m"},"cwd":"/x"}' | HOME="$H" bash "$REPO/host/claude/statusline.sh")"
check "statusline silent when up to date" '! printf %s "$SL" | grep -q "brain update"'
printf 'garbage\n' > "$UPD/available"; mkdir -p "$UPD/available.lock"
check "silent on a malformed record" \
  '[ -z "$(echo "{}" | HOME="$H" "$REPO/host/claude/hooks/update-notice.sh")" ]'
rmdir "$UPD/available.lock"

echo "== auto-update is opt-in and careful =="
# A stand-in checkout whose `brain update` only records that it ran, so the
# unattended path is exercised without pulling or building anything.
FAKE="$TMP/fakerepo"; mkdir -p "$FAKE/host/bin"
printf '#!/bin/sh\necho ran >> "$HOME/auto-ran"\n' > "$FAKE/host/bin/brain"; chmod +x "$FAKE/host/bin/brain"
git -C "$FAKE" init -q -b main
git -C "$FAKE" add -A && git -C "$FAKE" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$FAKE" -c user.name=t -c user.email=t@t tag -a v1.0.0 -m v1.0.0
auto() { HOME="$H" BRAIN_REPO_DIR="$FAKE" bash -c '. "$1/host/lib/common.sh"; update_auto_maybe' _ "$REPO"; }
runs() { wc -l < "$H/auto-ran" 2>/dev/null | tr -d ' ' || echo 0; }
printf 'behind=1 latest=v1.0.1 checked_at=%s\n' "$(date +%s)" > "$UPD/available"
auto
check "off by default" '[ ! -e "$H/auto-ran" ]'
HOME="$H" bash "$REPO/host/bin/brain" config autoupdate on >/dev/null 2>&1
check "brain config autoupdate on sets it" 'grep -q "^AUTOUPDATE=on" "$H/.config/brain/settings"'
auto
check "updates when on and behind" '[ "$(runs)" = 1 ]'
check "records the outcome" 'grep -q "result=ok from=v1.0.0" "$UPD/auto-result"'
auto
check "at most once a day" '[ "$(runs)" = 1 ]'
rm -f "$UPD/auto-attempted"; echo dirty >> "$FAKE/host/bin/brain"
auto
check "skips a checkout with local changes" '[ "$(runs)" = 1 ]'
git -C "$FAKE" checkout -q -- . && git -C "$FAKE" switch -q -c feature
auto
check "skips a checkout off main" '[ "$(runs)" = 1 ]'
NOTICE="$(echo '{}' | HOME="$H" "$REPO/host/claude/hooks/update-notice.sh")"
check "next session says it updated itself" \
  'printf %s "$NOTICE" | jq -e ".systemMessage | test(\"updated itself\")" >/dev/null'
check "and says it only once" '[ ! -e "$UPD/auto-result" ]'
HOME="$H" bash "$REPO/host/bin/brain" config autoupdate off >/dev/null 2>&1

echo "== uninstall puts it back =="
printf 'y\n' | HOME="$H" bash "$REPO/host/bin/brain" uninstall >/dev/null 2>&1
check "session start hook removed" \
  '! jq -r ".hooks.SessionStart[]?.hooks[].command" "$H/.claude/settings.json" | grep -q update-notice'
check "hooks removed"        '[ "$(jq -r ".hooks.PreToolUse | length" "$H/.claude/settings.json")" = "0" ] || ! jq -r ".hooks.PreToolUse[].hooks[].command" "$H/.claude/settings.json" | grep -q model-guard'
check "their own statusline still theirs" \
  '[ "$(jq -r .statusLine.command "$H/.claude/settings.json")" = "/Users/me/my-statusline.sh" ]'
check "brain commands gone"  '[ ! -e "$H/.local/bin/brain" ]'
check "credentials kept without --purge" '[ -d "$H/.config/brain" ]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

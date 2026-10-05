#!/usr/bin/env bash
# Account-set contract tests. What is being protected: an extra set of logins
# (say "work") must never share credentials, token, port or Claude config with
# another set, and a repo pinned to a set must always launch with that set's
# environment — including when the command is run from inside another set's
# session. The default set must behave exactly as before account sets existed.
#
# Everything runs against a sandbox HOME with stubbed services, tmux, claude and
# curl. No network, no real services, no sudo.
#
#   tests/accounts/run.sh
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
H="$TMP/home"; mkdir -p "$H"
CALLS="$TMP/calls"; : > "$CALLS"

# launchd and systemd --user are keyed by uid, not HOME: real ones here would
# touch the services of whatever brain runs on this machine. tmux likewise.
STUB="$TMP/stub"; mkdir -p "$STUB"
# systemctl: a unit is active once it has been enabled through the stub.
cat > "$STUB/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$CALLS"
for last; do :; done
case "\$*" in
  *"enable --now "*) echo "\$last" >> "$TMP/active" ;;
  *is-active*) grep -qx "\$last" "$TMP/active" 2>/dev/null; exit \$? ;;
esac
exit 0
EOF
# launchctl: nothing is loaded, so svc_install always renders the agent.
printf '#!/bin/sh\necho "launchctl $*" >> "%s"\n[ "$1" = print ] && exit 1\nexit 0\n' "$CALLS" > "$STUB/launchctl"
for tool in loginctl gh; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n[ "%s" = gh ] && exit 1\nexit 0\n' "$tool" "$CALLS" "$tool" > "$STUB/$tool"
done
# tmux: no sessions exist; record what would be launched, and keep the
# command of the last new-session so the test can run it for real.
cat > "$STUB/tmux" <<EOF
#!/bin/sh
echo "tmux \$*" >> "$CALLS"
case "\$1" in
  has-session) exit 1 ;;
  new-session) for last; do :; done; printf '%s' "\$last" > "$TMP/launch" ;;
esac
exit 0
EOF
# curl: the proxy answers (proxy_ready / proxy_models).
printf '#!/bin/sh\necho "curl $*" >> "%s"\necho "{\\"data\\":[]}"\nexit 0\n' "$CALLS" > "$STUB/curl"
# claude: report the environment it was started with.
printf '#!/bin/sh\nenv > "%s/claude.env"\nexit 0\n' "$TMP" > "$STUB/claude"
# Nothing is listening anywhere, whatever this machine is running.
printf '#!/bin/sh\nexit 0\n' > "$STUB/ss"
chmod +x "$STUB"/*

export HOME="$H" PATH="$STUB:$PATH"
unset BRAIN_ACCOUNT BRAIN_ACCOUNT_FLAG CLAUDE_CONFIG_DIR BRAIN_AUTH_DIR BRAIN_PROXY_PORT \
      BRAIN_PROXY_URL BRAIN_TOKEN_FILE BRAIN_CONFIG_DIR BRAIN_STATE_DIR BRAIN_DATA_DIR BRAIN_CLAUDE_CREDS

# A machine that already ran install.sh: proxy built, brain hooks registered,
# the user's own CLAUDE.md text around a brain block.
mkdir -p "$H/.local/share/brain/proxy/bin" "$H/.claude/skills/mine" "$H/.config/brain"
printf '#!/bin/sh\necho "proxy $*" >> "%s"\n' "$CALLS" > "$H/.local/share/brain/proxy/bin/cli-proxy-api"
chmod +x "$H/.local/share/brain/proxy/bin/cli-proxy-api"
printf 'default-token\n' > "$H/.config/brain/token"
cat > "$H/.claude/CLAUDE.md" <<'EOF'
# Machine
Never open firewall ports.
<!-- claude-brain:routing:start -->
brain routing text
<!-- claude-brain:routing:end -->
EOF
cat > "$H/.claude/settings.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Agent|Task","hooks":[{"type":"command","command":"$REPO/host/claude/hooks/model-guard.sh"}]}],
 "PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"$REPO/host/claude/hooks/consult-progress.sh"}]}],
 "SessionStart":[{"hooks":[{"type":"command","command":"$REPO/host/claude/hooks/update-notice.sh"}]}]},
 "statusLine":{"type":"command","command":"$REPO/host/claude/statusline.sh","refreshInterval":2}}
EOF

brain() { bash "$REPO/host/bin/brain" "$@"; }
resolve() { bash -c '. "$1/host/lib/common.sh"; eval "printf %s \"\$$2\""' _ "$REPO" "$1"; }

echo "== default set is unchanged =="
check "claude dir"   '[ "$(resolve BRAIN_CLAUDE_DIR)" = "$H/.claude" ]'
check "auth dir"     '[ "$(resolve BRAIN_AUTH_DIR)" = "$H/.cli-proxy-api" ]'
check "port"         '[ "$(resolve BRAIN_PROXY_PORT)" = 8317 ]'
check "token"        '[ "$(resolve BRAIN_TOKEN_FILE)" = "$H/.config/brain/token" ]'
check "usage cache"  '[ "$(resolve BRAIN_USAGE_DIR)" = "$H/.local/state/brain/usage" ]'
check "claude creds" '[ "$(resolve BRAIN_CLAUDE_CREDS)" = "$H/.claude/.credentials.json" ]'
check "proxy config template still renders 8317" \
  '[ "$(sed -e "s|__PORT__|8317|" "$REPO/host/templates/proxy-config.yaml.tmpl" | sed -n "s/^port: //p")" = 8317 ]'

echo "== an unknown or bad set fails closed =="
check "unknown set gets port 0, never 8317" \
  '[ "$(BRAIN_ACCOUNT=nope resolve BRAIN_PROXY_PORT)" = 0 ]'
check "commands refuse an unknown set" \
  '! brain --account nope status >/dev/null 2>&1'
check "bad names are refused" \
  '! brain --account "../x" status >/dev/null 2>&1 && ! brain account add "Work" >/dev/null 2>&1'

echo "== brain account add work =="
OUT="$(brain account add work 2>&1)"
check "succeeds"                '[ -f "$H/.config/brain/accounts/work/account" ]'
check "gets the first spare port" 'grep -qx PORT=8318 "$H/.config/brain/accounts/work/account"'
check "own proxy config on that port" \
  'grep -q "^port: 8318" "$H/.config/brain/accounts/work/proxy-config.yaml"'
check "own auth-dir" \
  'grep -q "auth-dir: \"$H/.cli-proxy-api-work\"" "$H/.config/brain/accounts/work/proxy-config.yaml"'
check "own token, not the default one" \
  '[ -s "$H/.config/brain/accounts/work/token" ] && ! grep -q default-token "$H/.config/brain/accounts/work/token"'
check "proxy config uses that token" \
  'grep -q "$(cat "$H/.config/brain/accounts/work/token")" "$H/.config/brain/accounts/work/proxy-config.yaml"'
check "credentials stay private" \
  '[ "$(stat -c %a "$H/.config/brain/accounts/work" 2>/dev/null || stat -f %Lp "$H/.config/brain/accounts/work")" = 700 ]'
if [ "$(uname -s)" = Darwin ]; then
  check "launchd agent for the set" \
    'grep -q "accounts/work/proxy-config.yaml" "$H/Library/LaunchAgents/sh.claude-brain.proxy-work.plist"'
else
  check "systemd template unit installed" '[ -f "$H/.config/systemd/user/cli-proxy-api@.service" ]'
  check "instance enabled" 'grep -q "systemctl --user enable --now cli-proxy-api@work" "$CALLS"'
fi
check "agents in the set's Claude dir" '[ -f "$H/.claude-work/agents/brain-sol.md" ]'
check "routing block in the set's CLAUDE.md" 'grep -q "claude-brain:routing:start" "$H/.claude-work/CLAUDE.md"'
check "user's own instructions carried over" 'grep -q "Never open firewall ports" "$H/.claude-work/CLAUDE.md"'
check "default brain block not duplicated" '[ "$(grep -c "brain routing text" "$H/.claude-work/CLAUDE.md")" = 0 ]'
check "skills linked" '[ -L "$H/.claude-work/skills" ]'
check "brain hooks registered for the set" \
  'jq -r ".hooks.PreToolUse[].hooks[].command" "$H/.claude-work/settings.json" | grep -q model-guard'
check "brain statusline for the set" \
  'jq -r ".statusLine.command" "$H/.claude-work/settings.json" | grep -q statusline.sh'
check "default settings untouched" \
  '[ "$(jq -r ".hooks.PreToolUse | length" "$H/.claude/settings.json")" = 1 ]'
check "says how to log in" 'printf %s "$OUT" | grep -q "brain auth anthropic --account work"'
brain account add work >/dev/null 2>&1
check "re-adding is idempotent" \
  '[ "$(jq -r ".hooks.PreToolUse | length" "$H/.claude-work/settings.json")" = 1 ] && grep -qx PORT=8318 "$H/.config/brain/accounts/work/account"'
brain account add client >/dev/null 2>&1
check "a second set gets the next port" 'grep -qx PORT=8319 "$H/.config/brain/accounts/client/account"'

echo "== the set resolves on its own =="
check "claude dir"  '[ "$(BRAIN_ACCOUNT=work resolve BRAIN_CLAUDE_DIR)" = "$H/.claude-work" ]'
check "claude creds" '[ "$(BRAIN_ACCOUNT=work resolve BRAIN_CLAUDE_CREDS)" = "$H/.claude-work/.credentials.json" ]'
check "usage cache" '[ "$(BRAIN_ACCOUNT=work resolve BRAIN_USAGE_DIR)" = "$H/.local/state/brain/accounts/work/usage" ]'
check "inherited default overrides do not leak in" \
  '[ "$(BRAIN_ACCOUNT=work BRAIN_AUTH_DIR=/x BRAIN_PROXY_PORT=8317 resolve BRAIN_PROXY_URL)" = http://127.0.0.1:8318 ] &&
   [ "$(BRAIN_ACCOUNT=work BRAIN_AUTH_DIR=/x resolve BRAIN_AUTH_DIR)" = "$H/.cli-proxy-api-work" ]'

echo "== repos pinned to a set =="
mkdir -p "$H/repos/core/.git" "$H/repos/mine/.git" "$H/repos/work/.git"
# Run the last tmux launch the way a tmux server would, from a polluted
# environment: another set's variables and a stray OAuth token, as when the
# server was first started from someone else's session.
run_launch() {
  rm -f "$TMP/claude.env"
  env BRAIN_ACCOUNT=client CLAUDE_CONFIG_DIR=/polluted BRAIN_TOKEN_FILE=/polluted/token \
      BRAIN_PROXY_URL=http://127.0.0.1:9999 BRAIN_AUTH_DIR=/polluted/auth CLAUDE_CODE_OAUTH_TOKEN=leak \
      BRAIN_ACCOUNT_FLAG=1 bash -c "$(cat "$TMP/launch")" </dev/null >/dev/null 2>&1
  [ -s "$TMP/claude.env" ]
}
envof() { sed -n "s/^$1=//p" "$TMP/claude.env"; }

brain repo add navigate-ai/core --account work >/dev/null 2>&1
check "assignment remembered" 'grep -qx core=work "$H/.config/brain/repo-accounts"'
check "the launch command runs" 'run_launch'
check "session gets the set's Claude config" '[ "$(envof CLAUDE_CONFIG_DIR)" = "$H/.claude-work" ]'
check "session gets the set's account name" '[ "$(envof BRAIN_ACCOUNT)" = work ]'
check "session gets the set's proxy"  '[ "$(envof BRAIN_PROXY_URL)" = http://127.0.0.1:8318 ]'
check "session gets the set's token"  '[ "$(envof BRAIN_TOKEN_FILE)" = "$H/.config/brain/accounts/work/token" ]'
check "session gets the set's proxy logins (hooks read them)" '[ "$(envof BRAIN_AUTH_DIR)" = "$H/.cli-proxy-api-work" ]'
check "a stray OAuth token cannot override the set's login" '[ -z "$(envof CLAUDE_CODE_OAUTH_TOKEN)" ]'
check "session does not inherit the explicit-choice flag" '[ -z "$(envof BRAIN_ACCOUNT_FLAG)" ]'
check "the leftover shell is inside the set's env too" \
  'grep -q "exec env .*bash -c" "$TMP/launch"'
check "folder trust lands in the set's .claude.json" \
  'jq -e ".projects[\"$H/repos/core\"].hasTrustDialogAccepted" "$H/.claude-work/.claude.json" >/dev/null && ! grep -q repos/core "$H/.claude.json" 2>/dev/null'

brain repo serve core >/dev/null 2>&1
check "serve without a flag uses the assigned set" 'run_launch && [ "$(envof BRAIN_ACCOUNT)" = work ]'
BRAIN_ACCOUNT=client CLAUDE_CONFIG_DIR="$H/.claude-client" brain repo serve core >/dev/null 2>&1
check "serve from inside another set's session still uses the assigned set" \
  'run_launch && [ "$(envof CLAUDE_CONFIG_DIR)" = "$H/.claude-work" ]'
brain repo serve core/ >/dev/null 2>&1
check "a trailing slash cannot dodge the pin" 'run_launch && [ "$(envof BRAIN_ACCOUNT)" = work ]'
check "odd repo names are refused" '! brain repo serve "co=re" >/dev/null 2>&1 && ! brain repo serve ../x >/dev/null 2>&1'
check "serve with a conflicting --account is refused" \
  '! brain repo serve core --account default >/dev/null 2>&1'

BRAIN_ACCOUNT=work CLAUDE_CONFIG_DIR="$H/.claude-work" brain repo add me/mine >/dev/null 2>&1
check "repo add from inside a work session does not pin to work" \
  '! grep -q "^mine=" "$H/.config/brain/repo-accounts"'
check "default repo scrubs an inherited CLAUDE_CONFIG_DIR" 'run_launch && [ -z "$(envof CLAUDE_CONFIG_DIR)" ]'
check "default repo uses the default proxy and token" \
  '[ "$(envof BRAIN_PROXY_URL)" = http://127.0.0.1:8317 ] && [ "$(envof BRAIN_TOKEN_FILE)" = "$H/.config/brain/token" ]'

brain repo add me/work >/dev/null 2>&1
REPO_SESSION="$(grep "tmux new-session" "$CALLS" | tail -1)"
brain --account work >/dev/null 2>&1
SET_SESSION="$(grep "tmux new-session" "$CALLS" | tail -1)"
check "a repo named like a set gets its own tmux session" \
  'printf %s "$REPO_SESSION" | grep -q -- "-s brain-rc-work " && printf %s "$SET_SESSION" | grep -q -- "-s brain-acct-work "'
check "tmux lookups are exact, never prefix matches" \
  '! grep -E "tmux (has|kill)-session -t [^=]" "$CALLS"'

brain multi --account work >/dev/null 2>&1
check "brain multi launch command runs (env options before assignments)" \
  'run_launch && [ "$(envof ANTHROPIC_BASE_URL)" = http://127.0.0.1:8318 ] && [ "$(envof CLAUDE_CONFIG_DIR)" = "$H/.claude-work" ]'
brain multi >/dev/null 2>&1
check "default brain multi still runs" 'run_launch && [ "$(envof ANTHROPIC_BASE_URL)" = http://127.0.0.1:8317 ]'

echo "== checkouts outside ~/repos =="
brain repo add org/elsewhere --dir "$H/Documents/nav/elsewhere" --account work >/dev/null 2>&1 || true
check "a failed clone leaves no pin and no link" \
  '! grep -q "^elsewhere=" "$H/.config/brain/repo-accounts" && [ ! -e "$H/repos/elsewhere" ]'
rm -rf "$H/Documents/nav"
mkdir -p "$H/Documents/nav"; git init -q "$H/Documents/nav/core2"
brain repo add org/core2 --dir "$H/Documents/nav/core2" --account work >/dev/null 2>&1
check "--dir links ~/repos/<name> to the checkout" \
  '[ -L "$H/repos/core2" ] && [ "$(cd -P "$H/repos/core2" && pwd)" = "$(cd -P "$H/Documents/nav/core2" && pwd)" ]'
check "--dir repo is pinned to its set" 'grep -qx core2=work "$H/.config/brain/repo-accounts"'
check "--dir repo session runs in the real checkout with the set's login" \
  'run_launch && [ "$(envof CLAUDE_CONFIG_DIR)" = "$H/.claude-work" ] && grep -q "cd $(cd -P "$H/Documents/nav/core2" && pwd)" "$TMP/launch"'
check "--dir refuses to replace a different checkout" \
  '! brain repo add org/core2 --dir "$H/Documents/other/core2" --account work >/dev/null 2>&1'
brain repo serve core2 >/dev/null 2>&1
check "serve finds a --dir repo through its link" 'run_launch && [ "$(envof BRAIN_ACCOUNT)" = work ]'
brain repo add core2 --account default >/dev/null 2>&1 || true
rm -f "$H/repos/core2"; sed -i.bak '/^core2=/d' "$H/.config/brain/repo-accounts"; rm -f "$H/.config/brain/repo-accounts.bak"

echo "== ports =="
check "8317 is refused for a set"        '! brain account add p1 --port 8317 >/dev/null 2>&1'
check "another set's port is refused"    '! brain account add p2 --port 8318 >/dev/null 2>&1'
check "out-of-range ports are refused"   '! brain account add p3 --port 80 >/dev/null 2>&1'
check "refused sets leave nothing behind" '[ ! -e "$H/.config/brain/accounts/p1/account" ] && [ ! -e "$H/.config/brain/accounts/p2/account" ]'
check "empty --account= is refused"      '! brain --account= status >/dev/null 2>&1'

echo "== statusline =="
mkdir -p "$H/.local/state/brain/accounts/work/usage" "$H/.local/state/brain/usage"
printf 'headroom=3 updated_at=%s\n' "$(date +%s)" > "$H/.local/state/brain/accounts/work/usage/summary.txt"
printf 'headroom=90 updated_at=%s\n' "$(date +%s)" > "$H/.local/state/brain/usage/summary.txt"
check "a set's statusline reads the set's headroom" \
  'echo "{}" | BRAIN_ACCOUNT=work bash "$REPO/host/claude/statusline.sh" 2>/dev/null | grep -q "3%"'

echo "== brain-ask inside a set =="
NATIVE="$H/.local/share/brain/native/0.4.1"; mkdir -p "$NATIVE"
printf '#!/bin/sh\necho NATIVE\n' > "$NATIVE/brain-compress"; chmod +x "$NATIVE/brain-compress"
echo 0.4.1 > "$NATIVE/VERSION"; ln -sfn 0.4.1 "$H/.local/share/brain/native/current"
check "default set keeps the native applet" \
  '[ "$(bash "$REPO/host/bin/brain-ask" x 2>/dev/null)" = NATIVE ]'
check "an old native applet is bypassed inside a set (it would read the default token)" \
  '[ "$(BRAIN_ACCOUNT=work bash "$REPO/host/bin/brain-ask" 2>/dev/null)" != NATIVE ]'
printf '#!/bin/sh\necho "$BRAIN_TOKEN_FILE $BRAIN_PROXY_URL"\n' > "$NATIVE/brain-compress"
echo 0.4.2 > "$NATIVE/VERSION"
check "brain-ask resolves the set itself, ignoring an inherited token/URL" \
  '[ "$(BRAIN_ACCOUNT=work BRAIN_TOKEN_FILE=/x BRAIN_PROXY_URL=http://127.0.0.1:8317 bash "$REPO/host/bin/brain-ask")" = "$H/.config/brain/accounts/work/token http://127.0.0.1:8318" ]'
check "and the default set inside a default session" \
  '[ "$(bash "$REPO/host/bin/brain-ask")" = "$H/.config/brain/token http://127.0.0.1:8317" ]'

echo "== status and removal =="
STATUS="$(brain status 2>&1)"
check "status lists the sets" 'printf %s "$STATUS" | grep -q "work — proxy :8318"'
check "rm refuses while a repo uses the set" '! brain account rm work --yes >/dev/null 2>&1'
check "rm without a terminal needs --yes" '! brain account rm client </dev/null >/dev/null 2>&1 && [ -d "$H/.config/brain/accounts/client" ]'
brain account rm client --yes --purge >/dev/null 2>&1
check "rm removes the set" '[ ! -d "$H/.config/brain/accounts/client" ] && [ ! -d "$H/.claude-client" ]'
brain repo add core --account default >/dev/null 2>&1
check "a repo can move back to default" '! grep -q "^core=" "$H/.config/brain/repo-accounts"'
brain account rm work --yes >/dev/null 2>&1
check "rm without --purge keeps the logins" '[ ! -d "$H/.config/brain/accounts/work" ] && [ -d "$H/.claude-work" ]'
check "and takes the brain wiring out of them" \
  '! grep -q "claude-brain:routing" "$H/.claude-work/CLAUDE.md" && [ ! -e "$H/.claude-work/agents/brain-sol.md" ]'
check "default set untouched throughout" \
  'grep -q default-token "$H/.config/brain/token" && grep -q "Never open firewall ports" "$H/.claude/CLAUDE.md" && [ ! -L "$H/.claude/skills" ]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

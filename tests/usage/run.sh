#!/usr/bin/env bash
# Offline contract tests for usage-aware routing. No network, no vendor creds:
# the Anthropic fetch is fed canned payloads via BRAIN_USAGE_FIXTURE.
#
#   tests/usage/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export BRAIN_REPO_DIR="$ROOT"
export BRAIN_STATE_DIR="$WORK/state"
export BRAIN_CONFIG_DIR="$WORK/config"
export BRAIN_AUTH_DIR="$WORK/auth"
export HOME="$WORK/home"
export BRAIN_ACCOUNT=default
unset BRAIN_ACCOUNT_FLAG
mkdir -p "$BRAIN_STATE_DIR" "$BRAIN_CONFIG_DIR" "$BRAIN_AUTH_DIR" "$HOME"

# shellcheck source=../../host/lib/common.sh
. "$ROOT/host/lib/common.sh"
mkdir -p "$BRAIN_USAGE_DIR"

# Defined AFTER the source on purpose: common.sh exports ok()/warn()/fail() of
# its own, which would shadow these if they were declared above.
t_ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { if ( set +o pipefail; eval "$2" ); then t_ok "$1"; else t_bad "$1 [$2]"; fi; }

GUARD="$ROOT/host/claude/hooks/model-guard.sh"
# shellcheck disable=SC2034  # consumed inside the quoted check strings below
SL_IN='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/x"}}'
FIX="$WORK/fixtures"; mkdir -p "$FIX"

# --- fixtures -------------------------------------------------------------
# Current payload shape: a `limits` array including a model-scoped weekly window
# that the flat seven_day_opus key reports as null.
cat > "$FIX/limits-tight.json" <<'J'
{"five_hour":{"utilization":17.0,"resets_at":"2030-01-01T00:00:00.123456+00:00"},
 "seven_day":{"utilization":37.0,"resets_at":"2030-01-02T00:00:00.123456+00:00"},
 "seven_day_opus":null,
 "limits":[{"kind":"session","group":"session","percent":17,"resets_at":"2030-01-01T00:00:00.1+00:00","scope":null},
           {"kind":"weekly_all","group":"weekly","percent":37,"resets_at":"2030-01-02T00:00:00.1+00:00","scope":null},
           {"kind":"weekly_scoped","group":"weekly","percent":66,"resets_at":"2030-01-02T00:00:00.1+00:00",
            "scope":{"model":{"display_name":"Fable"}}}]}
J
# Legacy flat shape, no `limits` array.
cat > "$FIX/flat-ok.json" <<'J'
{"five_hour":{"utilization":5,"resets_at":"2030-01-01T00:00:00Z"},
 "seven_day":{"utilization":9,"resets_at":"2030-01-02T00:00:00Z"}}
J
cat > "$FIX/flat-critical.json" <<'J'
{"five_hour":{"utilization":93,"resets_at":"2030-01-01T00:00:00Z"},
 "seven_day":{"utilization":41,"resets_at":"2030-01-02T00:00:00Z"}}
J
cat > "$FIX/opus-binds.json" <<'J'
{"five_hour":{"utilization":5,"resets_at":"2030-01-01T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2030-01-02T00:00:00Z"},
 "seven_day_opus":{"utilization":92,"resets_at":"2030-01-02T00:00:00Z"}}
J
cat > "$FIX/capped.json" <<'J'
{"five_hour":{"utilization":5,"resets_at":"2030-01-01T00:00:00Z"},
 "org_spend_cap_reached":true}
J
echo '{"hello":"world"}'                                  > "$FIX/garbage.json"
echo '{"five_hour":{"utilization":4000,"resets_at":0}}'   > "$FIX/out-of-range.json"
echo 'not json at all {{{'                                > "$FIX/malformed.json"

refresh() { BRAIN_USAGE_FIXTURE="$FIX/$1" usage_refresh_anthropic >/dev/null 2>&1; }
gate()    { usage_gate "$1" | head -1; }
hook() {
  printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s"}}' "$1" \
    | "$GUARD" >"$WORK/hook.out" 2>"$WORK/hook.err"; printf '%s' "$?"
}
# Credential records carry a token so the Codex probe exercises its real read
# path; the value doubles as the leak canary asserted further down.
link() {
  printf '{"access_token":"faketoken-should-not-leak","account_id":"acct-1","type":"%s"}\n' \
    "$1" > "$BRAIN_AUTH_DIR/$1-test.json"
  usage_refresh_vendors
}
unlink_all() { rm -f "$BRAIN_AUTH_DIR"/*.json; usage_refresh_vendors; }
fresh()  { rm -f "$BRAIN_USAGE_DIR/.last-advice"; }

echo "== payload parsing =="
refresh limits-tight.json
check "limits array preferred over flat keys" '[ "$(usage_field bind)" = "weekly_scoped_fable" ]'
check "model-scoped window binds (66% used)" '[ "$(usage_field headroom)" = "34" ]'
check "windows listed for display"           'usage_field windows | grep -q "session:17,weekly_all:37"'
check "fractional-offset resets_at parsed"   '[ "$(usage_field resets_in)" -gt 0 ]'
check "resets_raw kept out of summary"       '! grep -q resets_raw "$BRAIN_USAGE_SUMMARY"'

refresh opus-binds.json
check "flat shape: opus binds over five_hour" '[ "$(usage_field bind)" = "seven_day_opus" ]'
check "flat shape: headroom from opus"        '[ "$(usage_field headroom)" = "8" ]'

echo "== bands respond to live thresholds =="
refresh limits-tight.json
check "34% headroom is tight"                '[ "$(usage_state)" = "tight" ]'
setting_set USAGE_RESERVE_PCT 40
check "raising reserve makes it critical"    '[ "$(usage_state)" = "critical" ]'
setting_set USAGE_RESERVE_PCT 15
setting_set USAGE_ADVISORY_PCT 20
check "lowering advisory makes it ok"        '[ "$(usage_state)" = "ok" ]'
setting_set USAGE_ADVISORY_PCT 35
refresh capped.json
check "org spend cap forces critical"        '[ "$(usage_state)" = "critical" ]'

echo "== fail-open cluster (every one must allow) =="
for f in garbage.json out-of-range.json malformed.json; do
  rm -f "$BRAIN_USAGE_SUMMARY"
  refresh "$f" || true
  check "$f -> unknown"                      '[ "$(usage_state)" = "unknown" ]'
  check "$f -> Explore allowed"              '[ "$(gate Explore)" = "allow" ]'
done
rm -f "$BRAIN_USAGE_SUMMARY"
BRAIN_CLAUDE_CREDS="$WORK/nope.json" BRAIN_CLAUDE_KEYCHAIN_SERVICE="" usage_refresh_anthropic >/dev/null 2>&1 || true
check "missing credentials -> unknown"       '[ "$(usage_state)" = "unknown" ]'
check "missing credentials -> allowed"       '[ "$(gate Explore)" = "allow" ]'
check "missing credentials -> reason logged" 'usage_last_error | grep -q no-credentials'

mkdir -p "$WORK/creds"
echo '{"claudeAiOauth":{"accessToken":"faketoken-should-not-leak","expiresAt":1000}}' > "$WORK/creds/c.json"
BRAIN_CLAUDE_CREDS="$WORK/creds/c.json" usage_refresh_anthropic >/dev/null 2>&1 || true
check "expired token -> reason logged"       'usage_last_error | grep -q token-expired'
check "token never written to state"         '! grep -rq faketoken-should-not-leak "$BRAIN_STATE_DIR"'

mkdir -p "$WORK/kcbin"
cat > "$WORK/kcbin/security" <<'SEC'
#!/bin/sh
[ "$5" = "brain-test-service" ] || exit 44
echo '{"claudeAiOauth":{"accessToken":"kc-token-should-not-leak","expiresAt":1000}}'
SEC
chmod +x "$WORK/kcbin/security"
PATH="$WORK/kcbin:$PATH" BRAIN_CLAUDE_CREDS="$WORK/nope.json" BRAIN_CLAUDE_KEYCHAIN_SERVICE="brain-test-service" \
  usage_refresh_anthropic >/dev/null 2>&1 || true
check "keychain creds are read when no file"  'usage_last_error | grep -q token-expired'
check "keychain token never written to state" '! grep -rq kc-token-should-not-leak "$BRAIN_STATE_DIR"'

echo "== a failed refresh keeps the last good sample =="
refresh flat-critical.json
refresh garbage.json || true
check "previous sample survives a bad fetch" '[ "$(usage_field headroom)" = "7" ]'

echo "== the gate =="
link codex
refresh flat-critical.json
check "critical: Explore denied"             '[ "$(gate Explore)" = "deny" ]'
check "critical: Plan denied"                '[ "$(gate Plan)" = "deny" ]'
check "critical: general-purpose denied"     '[ "$(gate general-purpose)" = "deny" ]'
check "critical: brain-sol allowed"          '[ "$(gate brain-sol)" = "allow" ]'
check "critical: brain-astra allowed"         '[ "$(gate brain-astra)" = "allow" ]'
check "critical: brain-grok allowed"         '[ "$(gate brain-grok)" = "allow" ]'
check "critical: empty agent allowed"        '[ "$(gate "")" = "allow" ]'
refresh flat-ok.json
check "ok: Explore allowed silently"         '[ "$(gate Explore)" = "allow" ]'
refresh limits-tight.json
check "tight: Explore advised, not denied"   '[ "$(gate Explore)" = "advise" ]'

echo "== safety valves (each downgrades a deny to advise) =="
refresh flat-critical.json
unlink_all
check "valve 1: no consultant linked"        '[ "$(gate Explore)" = "advise" ]'
link codex
check "  ...and denies again once linked"    '[ "$(gate Explore)" = "deny" ]'
printf '%s\n' "$(( $(date +%s) + 600 ))" > "$BRAIN_USAGE_OVERRIDE_FILE"
check "valve 3: override file"               '[ "$(gate Explore)" = "advise" ]'
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$BRAIN_USAGE_OVERRIDE_FILE"
check "  ...expired override does not count" '[ "$(gate Explore)" = "deny" ]'
rm -f "$BRAIN_USAGE_OVERRIDE_FILE"
check "valve 3: env override"                '[ "$(BRAIN_USAGE_OVERRIDE=1 gate Explore)" = "advise" ]'
setting_set USAGE_ENFORCE advisory
check "enforce=advisory never denies"        '[ "$(gate Explore)" = "advise" ]'
setting_set USAGE_ENFORCE off
check "enforce=off is fully silent"          '[ "$(gate Explore)" = "allow" ]'
setting_set USAGE_ENFORCE block

echo "== stale samples age out =="
refresh flat-critical.json
# Not `sed -i`: BSD sed requires a backup suffix, so that form dies on macOS.
age_sample() {
  awk -v t="$1" '{sub(/updated_at=[0-9]+/, "updated_at=" t); print}' "$2" > "$WORK/aged" \
    && mv "$WORK/aged" "$2"
}
age_sample "$(( $(date +%s) - BRAIN_USAGE_MAX_AGE - 60 ))" "$BRAIN_USAGE_SUMMARY"
check "sample older than its window -> unknown" '[ "$(usage_state)" = "unknown" ]'
check "stale sample -> allowed"                 '[ "$(gate Explore)" = "allow" ]'

echo "== ChatGPT / Codex headroom (x-codex-* response headers) =="
# Codex only reports usage as response headers on a real POST, so the probe is
# fed canned header dumps via BRAIN_CODEX_FIXTURE instead of hitting the network.
cat > "$FIX/codex-ok.hdr" <<'H'
HTTP/2 200
x-codex-active-limit: premium
x-codex-plan-type: prolite
x-codex-primary-used-percent: 2
x-codex-secondary-used-percent: 0
x-codex-primary-window-minutes: 10080
x-codex-primary-reset-after-seconds: 370830
x-codex-credits-has-credits: False
H
cat > "$FIX/codex-exhausted.hdr" <<'H'
HTTP/2 200
x-codex-plan-type: prolite
x-codex-primary-used-percent: 91
x-codex-secondary-used-percent: 12
x-codex-primary-reset-after-seconds: 3600
x-codex-credits-has-credits: True
H
cat > "$FIX/codex-secondary.hdr" <<'H'
HTTP/2 200
x-codex-plan-type: pro
x-codex-primary-used-percent: 4
x-codex-secondary-used-percent: 88
H
# What a Cloudflare managed challenge looks like: 403, and no x-codex-* at all.
printf 'HTTP/2 403\ncf-ray: abc123\ncontent-type: text/html\n' > "$FIX/codex-challenged.hdr"
printf 'HTTP/2 200\nx-codex-primary-used-percent: 4000\n'       > "$FIX/codex-insane.hdr"

probe() { BRAIN_CODEX_FIXTURE="$FIX/$1" usage_refresh_codex >/dev/null 2>&1; }
link codex

probe codex-ok.hdr
check "codex headroom parsed"                '[ "$(usage_codex_field headroom)" = "98" ]'
check "codex plan parsed"                    '[ "$(usage_codex_field plan)" = "prolite" ]'
check "codex reset seconds parsed"           '[ "$(usage_codex_field resets_in)" = "370830" ]'
check "codex state ok"                       '[ "$(usage_codex_state)" = "ok" ]'
check "healthy codex stays a lane"           'usage_refresh_vendors; usage_rank_lanes | grep -q chatgpt'

probe codex-secondary.hdr
check "secondary window can bind"            '[ "$(usage_codex_field headroom)" = "12" ]'
check "  ...and that is critical"            '[ "$(usage_codex_state)" = "critical" ]'

probe codex-exhausted.hdr
check "exhausted codex -> critical"          '[ "$(usage_codex_state)" = "critical" ]'
usage_refresh_vendors
check "exhausted codex marked reserve"       'grep -q "chatgpt reserve" "$BRAIN_USAGE_VENDORS"'
check "exhausted codex dropped from lanes"   '! usage_rank_lanes | grep -q chatgpt'
refresh flat-critical.json
check "both exhausted + no other lane -> advise" '[ "$(gate Explore)" = "advise" ]'
link xai
check "  ...but grok still absorbs the deny" '[ "$(gate Explore)" = "deny" ]'

probe codex-ok.hdr; usage_refresh_vendors
check "deny message cites codex headroom"    'usage_gate Explore | grep -q "ChatGPT is at 98% headroom"'

# A failed probe reports failure and leaves the last good sample alone, exactly
# like the Anthropic fetch — it must never overwrite good data with a guess.
check "cloudflare challenge -> probe fails"  '! probe codex-challenged.hdr'
check "  ...last good sample survives"       '[ "$(usage_codex_field headroom)" = "98" ]'
check "out-of-range percent rejected"        '! probe codex-insane.hdr'
check "  ...last good sample still there"    '[ "$(usage_codex_field headroom)" = "98" ]'
rm -f "$BRAIN_CODEX_STATE"
check "failed probe, no prior -> unknown"    '! probe codex-challenged.hdr; [ "$(usage_codex_state)" = "unknown" ]'
check "unknown codex never blocks a lane"    'usage_refresh_vendors; usage_rank_lanes | grep -q chatgpt'
probe codex-ok.hdr
printf 'updated_at=%s headroom=98\n' "$(( $(date +%s) - 90000 ))" > "$BRAIN_CODEX_STATE"
check "codex sample older than a day ages out" '[ "$(usage_codex_state)" = "unknown" ]'
probe codex-ok.hdr
setting_set USAGE_PROBE off
check "probe off -> no token is spent"       '! BRAIN_CODEX_FIXTURE="$FIX/codex-exhausted.hdr" usage_refresh_codex'
check "  ...and the old sample is untouched" '[ "$(usage_codex_field headroom)" = "98" ]'
setting_set USAGE_PROBE on
rm -f "$BRAIN_AUTH_DIR"/codex-*.json
check "unlinked codex -> probe refuses"      '! probe codex-ok.hdr'
printf '{"type":"codex"}\n' > "$BRAIN_AUTH_DIR/codex-test.json"
check "tokenless record -> probe refuses"    '! probe codex-ok.hdr'
link codex
check "codex token never written to state"   '! grep -rq faketoken-should-not-leak "$BRAIN_STATE_DIR"'

echo "== vendor cooldown records (.cds) =="
refresh flat-ok.json
link xai
check "linked vendors ranked"                'usage_rank_lanes | grep -q grok'
cat > "$BRAIN_AUTH_DIR/xai-test.cds" <<J
{"records":[{"provider":"xai","model":"grok-4.5","status":"cooldown",
             "quota":{"exceeded":true,"next_recover_at":"2030-01-01T00:00:00Z"}}]}
J
usage_refresh_vendors
check "cooldown vendor detected"             'vendor_cooldown grok | grep -q blocked'
check "cooldown vendor dropped from lanes"   '! usage_rank_lanes | grep -q grok'
cat > "$BRAIN_AUTH_DIR/xai-test.cds" <<J
{"records":[{"provider":"xai","model":"grok-4.5","status":"cooldown",
             "quota":{"exceeded":true,"next_recover_at":"2000-01-01T00:00:00Z"}}]}
J
check "past recovery time is not a cooldown" '! vendor_cooldown grok'
rm -f "$BRAIN_AUTH_DIR/xai-test.cds"

echo "== the hook =="
link codex
refresh flat-critical.json; fresh
check "hook denies Explore with exit 2"      '[ "$(hook Explore)" = "2" ]'
check "hook deny explains the reserve"       'grep -q "preserve the Claude reserve" "$WORK/hook.err"'
check "hook deny names an alternative"       'grep -q "brain-sol" "$WORK/hook.err"'
check "hook deny names the override"         'grep -q "usage override" "$WORK/hook.err"'
check "hook allows brain-sol"                '[ "$(hook brain-sol)" = "0" ]'
check "hook allows brain-astra"               '[ "$(hook brain-astra)" = "0" ]'
unlink_all
check "unlinked-vendor deny still fires"     '[ "$(hook brain-sol)" = "2" ]'
check "  ...for brain-astra too"              '[ "$(hook brain-astra)" = "2" ]'
check "  ...with the original message"       'grep -q "brain auth chatgpt" "$WORK/hook.err"'
link codex

refresh limits-tight.json; fresh
check "hook advises once at tight"           '[ "$(hook Explore)" = "0" ] && grep -q additionalContext "$WORK/hook.out"'
check "  ...then rate-limits the repeat"     '[ "$(hook Explore)" = "0" ] && [ ! -s "$WORK/hook.out" ]'
refresh flat-ok.json; fresh
check "hook silent at ok"                    '[ "$(hook Explore)" = "0" ] && [ ! -s "$WORK/hook.out" ]'
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "$GUARD" >/dev/null 2>&1
check "hook ignores non-Agent tools"         '[ "$?" -eq 0 ]'

echo "== emitted JSON is well formed =="
refresh limits-tight.json; fresh
hook Explore >/dev/null
check "PreToolUse payload parses"            'jq -e . < "$WORK/hook.out" >/dev/null'
fresh
echo '{}' | "$ROOT/host/claude/hooks/consult-progress.sh" > "$WORK/prog.out" 2>/dev/null || true
check "PostToolUse payload parses"           'jq -e .systemMessage < "$WORK/prog.out" >/dev/null'
check "  ...and carries the headroom"        'jq -re .systemMessage < "$WORK/prog.out" | grep -q "34% headroom"'

echo "== statusline (read-only, no fetch) =="
refresh limits-tight.json
check "statusline shows tight headroom"      'printf "%s" "$SL_IN" | "$ROOT/host/claude/statusline.sh" | grep -q "34% claude"'
refresh flat-critical.json
check "statusline flags the reserve"         'printf "%s" "$SL_IN" | "$ROOT/host/claude/statusline.sh" | grep -q reserve'
refresh flat-ok.json
check "statusline silent at ok"              '! printf "%s" "$SL_IN" | "$ROOT/host/claude/statusline.sh" | grep -q claude%'
rm -f "$BRAIN_USAGE_SUMMARY"
check "statusline silent with no sample"     'printf "%s" "$SL_IN" | "$ROOT/host/claude/statusline.sh" | grep -q "Opus 5"'

echo "== corrupt / skewed summaries never produce a false alarm =="
refresh flat-critical.json
printf 'updated_at=%s bind=weekly\n' "$(date +%s)" > "$BRAIN_USAGE_SUMMARY"   # headroom missing
check "truncated summary -> unknown"         '[ "$(usage_state)" = "unknown" ]'
check "truncated summary -> allowed"         '[ "$(gate Explore)" = "allow" ]'
check "truncated summary -> statusline mute" '! printf "%s" "$SL_IN" | "$ROOT/host/claude/statusline.sh" | grep -q claude'
check "truncated summary -> --json is valid" '"$ROOT/host/bin/brain" usage --json 2>/dev/null | jq -e ".anthropic.headroom == null" >/dev/null'
printf 'updated_at=99999999999 headroom=5 bind=weekly\n' > "$BRAIN_USAGE_SUMMARY"
check "future timestamp -> unknown"          '[ "$(usage_state)" = "unknown" ]'
check "future timestamp -> statusline mute"  '! printf "%s" "$SL_IN" | "$ROOT/host/claude/statusline.sh" | grep -q claude'

echo "== Meta Muse headroom (response.subscription_usage event) =="
# The router strips this event, so usage_refresh_muse probes for it; tests feed
# canned SSE bodies via BRAIN_MUSE_FIXTURE instead of hitting the network.
musefix() {
  printf 'event: response.completed\ndata: {"type":"response.completed"}\n\nevent: response.subscription_usage\ndata: {"subscription":{"tier":"1234567890123456","weekly":{"resets_at":%s,"used_percent":%s},"window":{"resets_at":%s,"used_percent":%s,"window_duration_mins":300}},"type":"response.subscription_usage"}\n\n' \
    "$(( $(date +%s) + 86400 ))" "$2" "$(( $(date +%s) + 3600 ))" "$1" > "$FIX/muse-$1-$2.sse"
}
muse_probe() { musefix "$1" "$2"; BRAIN_MUSE_FIXTURE="$FIX/muse-$1-$2.sse" usage_refresh_muse >/dev/null 2>&1; }
printf '{"api_key":"faketoken-should-not-leak","subs_tier_name":"Muse Code High Usage","type":"meta"}\n' \
  > "$BRAIN_AUTH_DIR/meta-test.json"
muse_probe 10 80
check "muse headroom = worst window"         '[ "$(usage_muse_field headroom)" = "20" ]'
check "muse plan parsed"                     '[ "$(usage_muse_field plan)" = "High_Usage" ]'
check "muse 5h reset parsed"                 'r="$(usage_muse_field resets_in)"; [ "$r" -gt 3500 ] && [ "$r" -le 3600 ]'
check "20% headroom is tight"                '[ "$(usage_muse_state)" = "tight" ]'
muse_probe 10 30
check "muse state ok"                        '[ "$(usage_muse_state)" = "ok" ]'
check "healthy muse stays a lane"            'usage_refresh_vendors; usage_rank_lanes | grep -q muse'
muse_probe 7.5 2
check "float percent truncated"              '[ "$(usage_muse_field window)" = "7" ]'
muse_probe 95 40
check "5h window can bind -> critical"       '[ "$(usage_muse_state)" = "critical" ]'
usage_refresh_vendors
check "exhausted muse marked reserve"        'grep -q "muse reserve" "$BRAIN_USAGE_VENDORS"'
check "exhausted muse dropped from lanes"    '! usage_rank_lanes | grep -q muse'
printf 'event: response.completed\ndata: {"type":"response.completed"}\n\n' > "$FIX/muse-none.sse"
cp "$BRAIN_MUSE_STATE" "$FIX/muse-before"
check "no usage event -> state untouched"    '! BRAIN_MUSE_FIXTURE="$FIX/muse-none.sse" usage_refresh_muse && [ "$(cat "$BRAIN_MUSE_STATE")" = "$(cat "$FIX/muse-before")" ]'
check "muse key never written to state"      '! grep -rq faketoken "$BRAIN_USAGE_DIR"'
rm -f "$BRAIN_AUTH_DIR/meta-test.json" "$BRAIN_MUSE_STATE"
usage_refresh_vendors

echo "== CLI =="
refresh limits-tight.json
check "brain usage --json parses"            '"$ROOT/host/bin/brain" usage --json | jq -e .state >/dev/null'
check "brain usage --json state=tight"       '"$ROOT/host/bin/brain" usage --json | jq -re .state | grep -qx tight'
check "brain usage --json exposes windows"   '"$ROOT/host/bin/brain" usage --json | jq -e ".anthropic.windows.weekly_scoped_fable == 66" >/dev/null'
check "brain usage table renders"            '"$ROOT/host/bin/brain" usage 2>/dev/null | grep -q "weekly_scoped_fable"'
# Grok/Kimi have no reachable usage endpoint and must never be given a number;
# ChatGPT and Muse do, and must show the real one.
link xai
check "grok/kimi never given a number"       '! "$ROOT/host/bin/brain" usage 2>/dev/null | grep -E "^  (grok|kimi) " | grep -q "%"'
check "grok says so explicitly"              '"$ROOT/host/bin/brain" usage 2>/dev/null | grep "^  grok " | grep -q "not measurable"'
check "chatgpt headroom reported for real"   'probe codex-ok.hdr; "$ROOT/host/bin/brain" usage 2>/dev/null | grep -q "chatgpt.*headroom 98%"'
check "chatgpt in --json"                    '"$ROOT/host/bin/brain" usage --json | jq -e ".chatgpt.headroom == 98" >/dev/null'
check "muse headroom reported for real"      'printf "{\"api_key\":\"k\",\"subs_tier_name\":\"Muse Code High Usage\",\"type\":\"meta\"}\n" > "$BRAIN_AUTH_DIR/meta-test.json"; muse_probe 10 30; "$ROOT/host/bin/brain" usage 2>/dev/null | grep -q "muse.*headroom 70%"'
check "muse in --json"                       '"$ROOT/host/bin/brain" usage --json | jq -e ".muse.headroom == 70 and .muse.window_used == 10" >/dev/null'
check "unread muse is stated, not faked"     'rm -f "$BRAIN_MUSE_STATE"; "$ROOT/host/bin/brain" usage 2>/dev/null | grep "^  muse " | grep -q "not read yet"'
check "probe off is stated, not faked"       'setting_set USAGE_PROBE off; rm -f "$BRAIN_CODEX_STATE"; "$ROOT/host/bin/brain" usage 2>/dev/null | grep -q "probe off"'
setting_set USAGE_PROBE on
check "brain usage override writes expiry"   '"$ROOT/host/bin/brain" usage override 5 >/dev/null && usage_override_active'
rm -f "$BRAIN_USAGE_OVERRIDE_FILE"
check "brain config usage reserve"           '"$ROOT/host/bin/brain" config usage reserve 25 >/dev/null && [ "$(usage_reserve_pct)" = "25" ]'
check "absurd reserve rejected"              '! "$ROOT/host/bin/brain" config usage reserve 99 >/dev/null 2>&1'
check "bad enforce mode rejected"            '! "$ROOT/host/bin/brain" config usage nonsense >/dev/null 2>&1'
setting_set USAGE_RESERVE_PCT 15
check "brain help lists usage"               '"$ROOT/host/bin/brain" help | grep -q "brain usage"'

echo "== routing strategies and credits =="
cat > "$FIX/flat-credits.json" <<'J'
{"five_hour":{"utilization":100,"resets_at":"2030-01-01T00:00:00Z"},
 "extra_usage":{"is_enabled":true}}
J
cat > "$FIX/flat-credits-capped.json" <<'J'
{"five_hour":{"utilization":100,"resets_at":"2030-01-01T00:00:00Z"},
 "extra_usage":{"is_enabled":true,"spend_limit_reached":true}}
J
cat > "$FIX/codex-spent.hdr" <<'H'
HTTP/2 200
x-codex-plan-type: prolite
x-codex-primary-used-percent: 100
x-codex-secondary-used-percent: 12
x-codex-credits-has-credits: True
H
check "routing defaults to reserve"          '[ "$(routing_strategy)" = "reserve" ]'
probe codex-ok.hdr; usage_refresh_vendors
refresh limits-tight.json
check "missing extra field defaults off"    '[ "$(usage_field extra)" = "0" ]'
check "reserve advisory band unchanged"     '[ "$(gate Explore)" = "advise" ]'
setting_set ROUTING_STRATEGY claude-first
check "claude-first defaults credits last"  '[ "$(routing_credits)" = "last" ]'
check "claude-first skips advisory band"     '[ "$(gate Explore)" = "allow" ]'
fresh
check "claude-first hook silent above reserve" '[ "$(hook Explore)" = "0" ] && [ ! -s "$WORK/hook.out" ]'
refresh flat-critical.json
check "Claude reserve uses ChatGPT tier"     '[ "$(routing_tier)" = "chatgpt-sub" ]'
check "Claude reserve + ChatGPT room denies" '[ "$(gate Explore)" = "deny" ]'
check "deny quotes ChatGPT subscription room" 'usage_gate Explore | grep -q "ChatGPT subscription has 98% headroom"'
check "claude-first override still works"   '[ "$(BRAIN_USAGE_OVERRIDE=1 gate Explore)" = "advise" ]'
check "claude-first advisory valve works"   'setting_set USAGE_ENFORCE advisory; [ "$(gate Explore)" = "advise" ]; setting_set USAGE_ENFORCE block'
check "claude-first off stays silent"       'setting_set USAGE_ENFORCE off; [ "$(gate Explore)" = "allow" ]; setting_set USAGE_ENFORCE block'
refresh flat-credits.json
check "extra usage enabled is cached"       '[ "$(usage_field extra)" = "1" ]'
check "binding cap derives on credits"      '[ "$(usage_field on_credits)" = "1" ]'
check "credits + ChatGPT room deny mentions credits" 'usage_gate Explore | grep -q "now on extra-usage credits"'
fresh
check "on-credits hook denies"              '[ "$(hook Explore)" = "2" ]'
check "on-credits hook explains credits"    'grep -q "now on extra-usage credits" "$WORK/hook.err"'
check "repeated deny still blocks"          '[ "$(hook Explore)" = "2" ]'
check "repeated deny rate-limits detail"    '! grep -q "ChatGPT subscription has" "$WORK/hook.err"'
refresh flat-credits-capped.json
check "spend cap is not usable credits"     '[ "$(usage_field cap)" = "1" ] && [ "$(usage_field on_credits)" = "0" ]'
refresh flat-credits.json
probe codex-secondary.hdr; usage_refresh_vendors
check "positive ChatGPT headroom is still subscription" '[ "$(routing_tier)" = "chatgpt-sub" ]'
check "claude-first keeps positive ChatGPT lane" 'usage_rank_lanes | grep -q chatgpt'
probe codex-spent.hdr; usage_refresh_vendors
check "spent Codex can still have credits"  '[ "$(usage_codex_field credits)" = "yes" ]'
check "both subscriptions spent use credits tier" '[ "$(routing_tier)" = "credits" ]'
check "both spent allow with credit advice" '[ "$(gate Explore)" = "advise" ]'
fresh
check "both spent hook allows with advice"  '[ "$(hook Explore)" = "0" ] && grep -q additionalContext "$WORK/hook.out"'
check "both spent advice prefers Claude credits" 'grep -q "Claude is preferred over OpenAI credits" "$WORK/hook.out"'
check "credit advice is rate-limited"       '[ "$(hook Explore)" = "0" ] && [ ! -s "$WORK/hook.out" ]'
check "usage shows routing tier and credit signals" '"$ROOT/host/bin/brain" usage > "$WORK/usage.out" 2>/dev/null; grep -q "routing=claude-first credits=last" "$WORK/usage.out" && grep -q "tier: credits" "$WORK/usage.out" && grep -q "extra usage: enabled" "$WORK/usage.out" && grep -q "credits: yes" "$WORK/usage.out"'
setting_set ROUTING_CREDITS allow
link xai
check "credits allow restores reserve deny" '[ "$(gate Explore)" = "deny" ]'
setting_set ROUTING_CREDITS last
cat > "$BRAIN_AUTH_DIR/codex-test.cds" <<'J'
{"records":[{"status":"cooldown","quota":{"exceeded":true,"next_recover_at":"2030-01-01T00:00:00Z"}}]}
J
probe codex-ok.hdr; usage_refresh_vendors
check "ChatGPT cooldown exhausts subscription" '[ "$(routing_tier)" = "credits" ]'
rm -f "$BRAIN_AUTH_DIR/codex-test.cds"
rm -f "$BRAIN_CODEX_STATE"
check "unknown ChatGPT fails open"          '[ "$(routing_tier)" = "claude-sub" ] && [ "$(gate Explore)" = "allow" ]'
probe codex-ok.hdr
unlink_all
check "unlinked ChatGPT fails open"         '[ "$(gate Explore)" = "allow" ]'
link codex
setting_set ROUTING_STRATEGY consultant-first
refresh flat-ok.json
check "consultant-first advises early"      '[ "$(gate Explore)" = "advise" ]'
setting_set ROUTING_STRATEGY reserve
check "reserve healthy behavior unchanged"  '[ "$(gate Explore)" = "allow" ]'

echo "== account settings overlay and CLI =="
mkdir -p "$BRAIN_ACCOUNTS_DIR/work" "$HOME/.claude-work"
printf 'PORT=8320\n' > "$BRAIN_ACCOUNTS_DIR/work/account"
printf 'User instructions stay here.\n' > "$HOME/.claude-work/CLAUDE.md"
setting_set ROUTING_STRATEGY claude-first
check "routing CLI writes only the account" '"$ROOT/host/bin/brain" config routing consultant-first --account work >/dev/null && grep -qx ROUTING_STRATEGY=consultant-first "$BRAIN_ACCOUNTS_DIR/work/settings"'
check "credits CLI writes the account"      '"$ROOT/host/bin/brain" config routing credits allow --account work >/dev/null && grep -qx ROUTING_CREDITS=allow "$BRAIN_ACCOUNTS_DIR/work/settings"'
check "account writes retain global routing" '[ "$(routing_strategy)" = "claude-first" ] && [ "$(routing_credits)" = "last" ]'
check "overlay wins, missing keys inherit global" '(export BRAIN_ACCOUNT=work; . "$ROOT/host/lib/common.sh"; [ "$(routing_strategy)" = "consultant-first" ] && [ "$(usage_reserve_pct)" = "15" ])'
check "usage CLI writes the account"        '"$ROOT/host/bin/brain" config usage reserve 22 --account work >/dev/null && grep -qx USAGE_RESERVE_PCT=22 "$BRAIN_ACCOUNTS_DIR/work/settings"'
check "account usage write retains global"  '[ "$(usage_reserve_pct)" = "15" ]'
check "config marks effective account overrides" '"$ROOT/host/bin/brain" config --account work | grep -q "USAGE_RESERVE_PCT = 22 (work override)"'
check "managed usage block records effective routing" 'grep -q "This account.*routing strategy: consultant-first, credits allow." "$HOME/.claude-work/CLAUDE.md"'
check "managed usage block preserves user text" 'grep -qx "User instructions stay here." "$HOME/.claude-work/CLAUDE.md"'
check "without explicit flag writes stay global" 'BRAIN_ACCOUNT=work "$ROOT/host/bin/brain" config routing reserve >/dev/null && [ "$(routing_strategy)" = "reserve" ] && grep -qx ROUTING_STRATEGY=consultant-first "$BRAIN_ACCOUNTS_DIR/work/settings"'
check "explicit default account writes global" '"$ROOT/host/bin/brain" config routing claude-first --account default >/dev/null && [ "$(routing_strategy)" = "claude-first" ]'
check "same-file overlay is harmless"       '(ln -s "$BRAIN_SETTINGS_FILE" "$WORK/settings-alias"; BRAIN_ACCOUNT_SETTINGS_FILE="$WORK/settings-alias"; setting_set_account ROUTING_CREDITS allow; [ -L "$WORK/settings-alias" ] && [ "$(setting_get ROUTING_CREDITS last)" = "allow" ])'
setting_set ROUTING_CREDITS last
check "invalid routing strategy rejected"   '! "$ROOT/host/bin/brain" config routing nonsense >/dev/null 2>&1'
check "invalid routing credits rejected"    '! "$ROOT/host/bin/brain" config routing credits nonsense >/dev/null 2>&1'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

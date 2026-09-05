#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts
# Shared helpers for claude-brain host scripts. Source, don't execute.
# Portable across macOS (bash 3.2 + BSD tools) and Linux (bash 4+ + GNU tools):
# keep this file free of bash-4 syntax, and route anything platform-specific
# through host/lib/platform.sh.

set -o pipefail

# Resolve this file's real directory without `readlink -f` (BSD readlink lacked
# it before macOS 12.3), then derive the repo root from it. This is what lets
# the repo live anywhere: ~/claude-brain on a droplet, ~/src/... on a Mac.
_brain_self="${BASH_SOURCE[0]}"
while [ -L "$_brain_self" ]; do
  _brain_dir="$(cd -P "$(dirname "$_brain_self")" && pwd)"
  _brain_self="$(readlink "$_brain_self")"
  case "$_brain_self" in /*) ;; *) _brain_self="$_brain_dir/$_brain_self" ;; esac
done
BRAIN_LIB_DIR="$(cd -P "$(dirname "$_brain_self")" && pwd)"
unset _brain_self _brain_dir
BRAIN_REPO_DIR="${BRAIN_REPO_DIR:-$(cd -P "$BRAIN_LIB_DIR/../.." && pwd)}"

# Everything platform-specific (os/arch, package manager, services, stat/timeout
# differences) lives in platform.sh. Sourcing it here means every script that
# sources common.sh gets the portable helpers automatically.
# shellcheck source=platform.sh
. "$BRAIN_LIB_DIR/platform.sh"
BRAIN_CONFIG_DIR="${BRAIN_CONFIG_DIR:-$HOME/.config/brain}"
BRAIN_DATA_DIR="${BRAIN_DATA_DIR:-$HOME/.local/share/brain}"
BRAIN_STATE_DIR="${BRAIN_STATE_DIR:-$HOME/.local/state/brain}"
BRAIN_AUTH_DIR="${BRAIN_AUTH_DIR:-$HOME/.cli-proxy-api}"

BRAIN_TOKEN_FILE="$BRAIN_CONFIG_DIR/token"
BRAIN_SETTINGS_FILE="$BRAIN_CONFIG_DIR/settings"
BRAIN_PROXY_CONFIG="$BRAIN_CONFIG_DIR/proxy-config.yaml"
BRAIN_PROXY_SRC="$BRAIN_DATA_DIR/proxy/src"
BRAIN_PROXY_BIN="$BRAIN_DATA_DIR/proxy/bin/cli-proxy-api"
BRAIN_PROXY_PORT="${BRAIN_PROXY_PORT:-8317}"
BRAIN_PROXY_URL="http://127.0.0.1:$BRAIN_PROXY_PORT"

BRAIN_PIN_FILE="$BRAIN_REPO_DIR/host/proxy/PIN"
# Vendored patches applied on top of the pinned commit. SERIES is a sha256sum-format
# manifest listing them in apply order; PIN records SERIES's own checksum, so a
# tampered patch or a reordered series fails the build instead of shipping silently.
BRAIN_PATCH_DIR="$BRAIN_REPO_DIR/host/proxy/patches"
BRAIN_PATCH_SERIES="$BRAIN_PATCH_DIR/SERIES"
PROXY_REPO_URL="https://github.com/router-for-me/CLIProxyAPI.git"

# Colors only when stdout is a terminal.
if [ -t 1 ]; then
  C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
  C_GREEN='' C_RED='' C_YELLOW='' C_BOLD='' C_RESET=''
fi

info()  { printf '%s\n' "${C_BOLD}==>${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN} ✓${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW} !${C_RESET} $*" >&2; }
fail()  { printf '%s\n' "${C_RED} ✗${C_RESET} $*" >&2; }
die()   { fail "$@"; exit 1; }

need() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required commands: ${missing[*]}"
}

# Read a KEY=VALUE user setting, falling back to a default: setting_get KEY DEFAULT
setting_get() {
  local val=""
  [ -f "$BRAIN_SETTINGS_FILE" ] && val="$(sed -n "s/^$1=//p" "$BRAIN_SETTINGS_FILE" | tail -1)"
  printf '%s\n' "${val:-$2}"
}

# Write a KEY=VALUE user setting: setting_set KEY VALUE
setting_set() {
  ensure_brain_dirs
  umask 077
  touch "$BRAIN_SETTINGS_FILE"
  { grep -v "^$1=" "$BRAIN_SETTINGS_FILE" || true; printf '%s=%s\n' "$1" "$2"; } \
    > "$BRAIN_SETTINGS_FILE.tmp"
  mv "$BRAIN_SETTINGS_FILE.tmp" "$BRAIN_SETTINGS_FILE"
}

# Read a KEY=VALUE entry from the PIN file.
pin_get() {
  [ -f "$BRAIN_PIN_FILE" ] || die "PIN file not found: $BRAIN_PIN_FILE"
  sed -n "s/^$1=//p" "$BRAIN_PIN_FILE"
}

ensure_brain_dirs() {
  umask 077
  mkdir -p "$BRAIN_CONFIG_DIR" "$BRAIN_DATA_DIR" "$BRAIN_STATE_DIR" "$BRAIN_AUTH_DIR"
  chmod 700 "$BRAIN_CONFIG_DIR" "$BRAIN_AUTH_DIR"
}

# Print the proxy API token, generating it on first use.
brain_token() {
  if [ ! -f "$BRAIN_TOKEN_FILE" ]; then
    ensure_brain_dirs
    umask 077
    openssl rand -hex 32 > "$BRAIN_TOKEN_FILE"
  fi
  chmod 600 "$BRAIN_TOKEN_FILE"
  cat "$BRAIN_TOKEN_FILE"
}

proxy_ready() {
  curl -fsS -m 5 -H "Authorization: Bearer $(brain_token)" \
    "$BRAIN_PROXY_URL/v1/models" >/dev/null 2>&1
}

# List model ids the proxy currently serves, one per line.
proxy_models() {
  curl -fsS -m 10 -H "Authorization: Bearer $(brain_token)" \
    "$BRAIN_PROXY_URL/v1/models" | jq -r '.data[].id'
}

# ---- vendor credential records (shared by `brain auth`, the hooks, and usage) ----

# Vendor name -> credential-record filename prefix under $BRAIN_AUTH_DIR.
vendor_record_prefix() {
  case "$1" in
    chatgpt) echo codex ;;
    grok)    echo xai ;;
    kimi)    echo kimi ;;
    claude)  echo claude ;;
    *)       return 1 ;;
  esac
}

# True when at least one credential record exists for the vendor.
vendor_linked() {
  local prefix f
  prefix="$(vendor_record_prefix "$1")" || return 1
  for f in "$BRAIN_AUTH_DIR/$prefix"-*.json; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# The consultant vendors usage-aware routing can offload onto. Anthropic is
# deliberately absent: it is what the reserve protects, never a fallback.
BRAIN_CONSULT_VENDORS="chatgpt grok kimi"

# ---- consultation progress (shared by the statusline, hooks, and `brain consult`) ----

BRAIN_CONSULT_DIR="$BRAIN_STATE_DIR/consult"
BRAIN_CONSULT_LINK="$BRAIN_CONSULT_DIR/current"

# True while a `brain-ask --stream` consultation is running, or finished within
# the last 45s so the completion stays visible for one more poll.
consult_active() {
  [ -e "$BRAIN_CONSULT_LINK" ] || return 1
  pgrep -f 'brain-ask ' >/dev/null 2>&1 && return 0
  local now mtime
  now="$(date +%s)"
  mtime="$(file_mtime "$BRAIN_CONSULT_LINK")"
  [ $((now - mtime)) -le 45 ]
}

# Latest reasoning-summary step from the `.thinking` sidecar, if any. Codex
# emits these as `**Bolded step**` headers, which read well as progress.
consult_thinking_step() {
  local t step
  t="$(abs_path "$BRAIN_CONSULT_LINK" 2>/dev/null || true).thinking"
  [ -f "$t" ] || return 0
  step="$(grep -o '\*\*[^*]\+\*\*' "$t" 2>/dev/null | tail -1 | tr -d '*')"
  [ ${#step} -le 64 ] || step="${step:0:61}..."
  printf '%s' "$step"
}

# One-line progress summary for the current consultation. Returns 1 when idle.
# xhigh models emit no answer text for minutes, so that window reports the live
# reasoning step instead — and falls back to a plain notice before one exists.
consult_progress_line() {
  consult_active || return 1
  local target name bytes heading step
  target="$(basename "$(abs_path "$BRAIN_CONSULT_LINK")")"
  name="${target%-*.log}"
  bytes="$(file_size "$BRAIN_CONSULT_LINK")"
  step="$(consult_thinking_step)"
  if [ "$bytes" -eq 0 ]; then
    if [ -n "$step" ]; then
      printf '%s · thinking: %s\n' "$name" "$step"
    else
      printf '%s · thinking, no output yet\n' "$name"
    fi
    return 0
  fi
  heading="$(grep -o '^#\+ .*' "$BRAIN_CONSULT_LINK" 2>/dev/null | tail -1 | sed 's/^#\+ *//')"
  local size
  if [ "$bytes" -lt 1024 ]; then size="${bytes}B"; else size="$((bytes / 1024))kB"; fi
  printf '%s · %s%s\n' "$name" "$size" "${heading:+ · writing: $heading}"
}

claude_bin() {
  if command -v claude >/dev/null 2>&1; then
    command -v claude
  elif [ -x "$HOME/.local/bin/claude" ]; then
    printf '%s\n' "$HOME/.local/bin/claude"
  else
    return 1
  fi
}

# ---- subscription usage (shared by the statusline, hooks, and `brain usage`) ----
#
# Two vendors report real headroom, by quite different means:
#
#   Anthropic — GET /api/oauth/usage, per-window utilization for the OAuth
#     subscription the session itself is spending. Free.
#   ChatGPT/Codex — `x-codex-*` response headers, which only ride along on a real
#     POST to /backend-api/codex/responses. See usage_refresh_codex below.
#
# Grok and Kimi expose nothing reachable, so they stay "unknown = available";
# their only negative signal is a `.cds` cooldown record written by the router
# after a quota error.
#
# Refresh is bash+curl rather than the Rust binary on purpose: brain-compress
# builds reqwest with no TLS feature (loopback proxy only), and adding rustls to
# it just to reach api.anthropic.com is a poor trade for ~40 lines of shell.

BRAIN_USAGE_DIR="$BRAIN_STATE_DIR/usage"
BRAIN_USAGE_SUMMARY="$BRAIN_USAGE_DIR/summary.txt"
BRAIN_USAGE_VENDORS="$BRAIN_USAGE_DIR/vendors.txt"
BRAIN_USAGE_STAMP="$BRAIN_USAGE_DIR/.last-fetch"
BRAIN_USAGE_LOCK="$BRAIN_USAGE_DIR/.refresh.lock"
BRAIN_USAGE_OVERRIDE_FILE="$BRAIN_USAGE_DIR/OVERRIDE"
BRAIN_CLAUDE_CREDS="${BRAIN_CLAUDE_CREDS:-$HOME/.claude/.credentials.json}"
BRAIN_USAGE_ENDPOINT="${BRAIN_USAGE_ENDPOINT:-https://api.anthropic.com/api/oauth/usage}"

# A cached sample older than the window it describes is meaningless.
BRAIN_USAGE_MAX_AGE=18000

usage_enforce()      { setting_get USAGE_ENFORCE block; }
usage_reserve_pct()  { setting_get USAGE_RESERVE_PCT 15; }
usage_advisory_pct() { setting_get USAGE_ADVISORY_PCT 35; }
usage_ttl() {
  local t; t="$(setting_get USAGE_TTL 90)"
  case "$t" in ''|*[!0-9]*) t=90 ;; esac
  [ "$t" -ge 30 ] || t=30
  printf '%s\n' "$t"
}

# Read one k=v field out of summary.txt. awk-only: this runs in the statusline
# at refreshInterval=2, so it must not spawn jq or curl.
usage_field() {
  [ -f "$BRAIN_USAGE_SUMMARY" ] || return 1
  local v
  v="$(awk -v k="$1" '{for(i=1;i<=NF;i++){split($i,p,"=");if(p[1]==k){print p[2];exit}}}' \
    "$BRAIN_USAGE_SUMMARY")" || return 1
  # A present-but-truncated summary must read as absent, not as an empty value:
  # callers splice this straight into `jq --argjson`, where "" is a parse error.
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# ok | tight | critical | unknown. Derived at read time from the cached raw
# headroom and the *current* thresholds, so changing `brain config usage
# reserve` takes effect immediately rather than at the next fetch. Anything
# unparseable, capped, or older than the window it describes is unknown — and
# unknown always fails open.
usage_state() {
  local headroom updated cap age now
  headroom="$(usage_field headroom 2>/dev/null || true)"
  updated="$(usage_field updated_at 2>/dev/null || true)"
  cap="$(usage_field cap 2>/dev/null || true)"
  case "$updated" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  now="$(date +%s)"; age=$((now - updated))
  # Too old to mean anything, or stamped in the future (clock skew / hand-edit).
  if [ "$age" -gt "$BRAIN_USAGE_MAX_AGE" ] || [ "$age" -lt -300 ]; then
    printf 'unknown\n'; return 0
  fi
  # An org spend cap is a hard stop regardless of window utilization.
  [ "$cap" = "1" ] && { printf 'critical\n'; return 0; }
  case "$headroom" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  if   [ "$headroom" -le "$(usage_reserve_pct)" ];  then printf 'critical\n'
  elif [ "$headroom" -le "$(usage_advisory_pct)" ]; then printf 'tight\n'
  else printf 'ok\n'
  fi
}

# True while a `brain usage override` grant is still in effect.
usage_override_active() {
  [ "${BRAIN_USAGE_OVERRIDE:-0}" = "1" ] && return 0
  [ -f "$BRAIN_USAGE_OVERRIDE_FILE" ] || return 1
  local until now
  until="$(cat "$BRAIN_USAGE_OVERRIDE_FILE" 2>/dev/null || echo 0)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$until" ]
}

# Per-vendor cooldown from the router's `.cds` records: prints "blocked <epoch>"
# while a quota error is still in effect, otherwise nothing. Absent file means
# unknown, never healthy — the router only writes one after a failure.
vendor_cooldown() {
  local prefix f now until best=0
  prefix="$(vendor_record_prefix "$1")" || return 1
  now="$(date +%s)"
  for f in "$BRAIN_AUTH_DIR/$prefix"-*.cds; do
    [ -e "$f" ] || continue
    # Go marshals these as RFC3339Nano, and jq's fromdateiso8601 rejects both a
    # fractional-second part and a numeric offset — so normalise to bare
    # "...Z" first, or every cooldown silently reads as "not in cooldown".
    until="$(jq -r '
      [ (.records // [])[]
        | select((.quota.exceeded // false) or ((.status // "") == "cooldown"))
        | (.quota.next_recover_at // .next_retry_after // empty)
        | tostring
        | sub("\\.[0-9]+"; "")
        | sub("(?<t>[+-][0-9]{2}):?[0-9]{2}$"; "Z")
        | sub("([^Z])$"; "\(.)Z")
      ] | map(fromdateiso8601? // 0) | max // 0' "$f" 2>/dev/null || echo 0)"
    case "$until" in ''|*[!0-9]*) until=0 ;; esac
    [ "$until" -gt "$best" ] && best="$until"
  done
  [ "$best" -gt "$now" ] || return 1
  printf 'blocked %s\n' "$best"
}

# Rewrite vendors.txt: one "<vendor> <linked|unlinked|blocked> [until]" per line.
# Purely local — no network, no credentials read.
usage_refresh_vendors() {
  local v state tmp
  tmp="$BRAIN_USAGE_VENDORS.tmp.$$"
  : > "$tmp"
  for v in $BRAIN_CONSULT_VENDORS; do
    if ! vendor_linked "$v"; then
      printf '%s unlinked\n' "$v" >> "$tmp"
    elif state="$(vendor_cooldown "$v")"; then
      printf '%s %s\n' "$v" "$state" >> "$tmp"
    elif [ "$v" = "chatgpt" ] && [ "$(usage_codex_state)" = "critical" ]; then
      # Measured, and out of room: same reserve rule as Claude.
      printf '%s reserve\n' "$v" >> "$tmp"
    else
      printf '%s linked\n' "$v" >> "$tmp"
    fi
  done
  mv "$tmp" "$BRAIN_USAGE_VENDORS"
}

# Consultant vendors that could take work right now, in BRAIN_CONSULT_VENDORS
# order. Usage only ever removes and demotes — it never reorders on quality,
# because for these vendors we have no quality-relevant signal at all.
usage_rank_lanes() {
  local out=() line v st
  if [ -f "$BRAIN_USAGE_VENDORS" ]; then
    while read -r v st _; do
      # "linked" only: unlinked, blocked (cooldown) and reserve are all excluded.
      [ "$st" = "linked" ] && out+=("$v")
    done < "$BRAIN_USAGE_VENDORS"
  else
    for v in $BRAIN_CONSULT_VENDORS; do
      vendor_linked "$v" && out+=("$v")
    done
  fi
  [ ${#out[@]} -gt 0 ] || return 1
  local IFS=,
  printf '%s\n' "${out[*]}"
}

# jq program turning an /api/oauth/usage body into shell-safe k=v tokens.
#
# Two payload shapes are handled. The current one carries a `limits` array whose
# entries include model-scoped weekly windows (e.g. weekly_scoped/Fable) that the
# flat `seven_day_opus` key reports as null — so `limits` is preferred, and
# missing it would silently understate real usage. The flat five_hour/seven_day/
# seven_day_opus keys are the fallback.
#
# Emits nothing (exit 1) when the payload matches neither shape: an unrecognised
# payload must degrade to "unknown", never to a wrong number.
read -r -d '' BRAIN_USAGE_JQ <<'JQ' || true
def slug: tostring | ascii_downcase | gsub("[^a-z0-9]+"; "_") | sub("^_+"; "") | sub("_+$"; "");
def flat($k): (.[$k] | if type == "object" then {u: .utilization, rs: .resets_at} else null end);
. as $root
| ([ (($root.limits // []) | if type == "array" then . else [] end)
     | .[]
     | select((.percent | type) == "number")
     | { k: ([(.kind // .group // "limit"), (.scope.model.display_name // empty)]
             | map(slug) | join("_")),
         u: .percent,
         rs: (.resets_at // null) }
   ]) as $from_limits
| ([ "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"
   ] | map(. as $k | (($root | flat($k)) // empty) | {k: $k, u: .u, rs: .rs})
     | map(select((.u | type) == "number"))) as $from_flat
| (if ($from_limits | length) > 0 then $from_limits else $from_flat end) as $rows
| select(($rows | length) > 0)
| select($rows | all(.u >= 0 and .u <= 100))
| ($rows | max_by(.u)) as $bind
| "windows=\($rows | map("\(.k):\(.u | round)") | join(","))",
  "bind=\($bind.k)",
  "headroom=\(100 - ($bind.u | ceil))",
  "resets_raw=\($bind.rs // "")"
JQ

# Fetch Anthropic usage and rewrite summary.txt. Returns 1 on any failure,
# leaving the previous sample in place for `usage_state` to age out.
usage_refresh_anthropic() {
  local token expires now body_file code rc=0 fields reason=""
  now="$(date +%s)"
  body_file="$BRAIN_USAGE_DIR/.body.$$"
  : > "$body_file" 2>/dev/null || true

  if [ -n "${BRAIN_USAGE_FIXTURE:-}" ]; then
    # Test path: read a canned payload instead of talking to the network.
    cp "$BRAIN_USAGE_FIXTURE" "$body_file" 2>/dev/null || reason="fixture-unreadable"
    code=200
  elif [ ! -f "$BRAIN_CLAUDE_CREDS" ]; then
    reason="no-credentials"
  else
    token="$(jq -r '.claudeAiOauth.accessToken // empty' "$BRAIN_CLAUDE_CREDS" 2>/dev/null || true)"
    expires="$(jq -r '.claudeAiOauth.expiresAt // empty' "$BRAIN_CLAUDE_CREDS" 2>/dev/null || true)"
    if [ -z "$token" ]; then
      reason="no-token"
    elif [ -n "$expires" ] && [ "${expires%%.*}" -lt "$((now * 1000))" ] 2>/dev/null; then
      # Expired. We never run the refresh exchange ourselves — rotating the
      # token out from under the live session could invalidate its login.
      reason="token-expired"
    else
      # Header on stdin, never argv: argv is world-readable via /proc.
      code="$(printf 'Authorization: Bearer %s\n' "$token" \
        | curl -sS -m 8 -H @- -H 'Content-Type: application/json' \
               -o "$body_file" -w '%{http_code}' "$BRAIN_USAGE_ENDPOINT" 2>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ] || reason="curl-$rc"
      [ -n "$reason" ] || [ "$code" = "200" ] || reason="http-$code"
    fi
  fi

  if [ -z "$reason" ]; then
    fields="$(jq -r "$BRAIN_USAGE_JQ" "$body_file" 2>/dev/null | tr '\n' ' ')" || fields=""
    [ -n "${fields// /}" ] || reason="unexpected-payload"
  fi

  if [ -n "$reason" ]; then
    rm -f "$body_file"
    printf '%s %s\n' "$now" "$reason" > "$BRAIN_USAGE_DIR/.last-error"
    return 1
  fi

  local cap resets_raw resets_at resets_in
  cap="$(jq -r 'if ((.org_spend_cap_reached // false) or (.extra_usage.spend_limit_reached // false))
                then 1 else 0 end' "$body_file" 2>/dev/null || echo 0)"
  rm -f "$body_file"
  resets_raw="$(printf '%s' "$fields" | awk '{for(i=1;i<=NF;i++){split($i,p,"=");if(p[1]=="resets_raw"){print substr($i,12)}}}')"
  # jq's fromdateiso8601 rejects both fractional seconds and numeric offsets,
  # which the endpoint emits — hence the conversion here rather than in jq.
  resets_at=0
  [ -n "$resets_raw" ] && resets_at="$(iso_to_epoch "$resets_raw" 2>/dev/null)"
  case "$resets_at" in ''|*[!0-9]*) resets_at=0 ;; esac
  resets_in=$(( resets_at > now ? resets_at - now : 0 ))
  # resets_raw is dropped from the summary: it is the only field that can carry
  # characters awk would have to quote, and resets_in supersedes it.
  fields="$(printf '%s' "$fields" | sed 's/resets_raw=[^ ]*//')"

  local tmp="$BRAIN_USAGE_SUMMARY.tmp.$$"
  printf 'updated_at=%s %scap=%s resets_in=%s\n' "$now" "$fields" "$cap" "$resets_in" > "$tmp"
  mv "$tmp" "$BRAIN_USAGE_SUMMARY"
  rm -f "$BRAIN_USAGE_DIR/.last-error"
  printf '%s\n' "$now" > "$BRAIN_USAGE_STAMP"
  return 0
}

usage_refresh_all() {
  # Codex first: vendors.txt folds its state in, so it must be current.
  local codex_last codex_now
  codex_now="$(date +%s)"
  codex_last="$(cat "$BRAIN_CODEX_STAMP" 2>/dev/null || echo 0)"
  case "$codex_last" in ''|*[!0-9]*) codex_last=0 ;; esac
  if [ $((codex_now - codex_last)) -ge "$(usage_probe_ttl)" ]; then
    usage_refresh_codex || true
  fi
  usage_refresh_vendors
  usage_refresh_anthropic || true
  # Stamp regardless of outcome so a hard-down endpoint backs off instead of
  # being retried on every single hook invocation.
  date +%s > "$BRAIN_USAGE_STAMP"
}

# Full refresh: local vendor states (free) plus the two network reads. Locked so
# concurrent hooks never stampede the endpoints — and a probe costs tokens, so
# "someone else is already doing it" must mean "do nothing", not "do it again".
usage_refresh() {
  ensure_brain_dirs
  mkdir -p "$BRAIN_USAGE_DIR"
  chmod 700 "$BRAIN_USAGE_DIR"
  command -v jq >/dev/null 2>&1 || return 1
  with_lock "$BRAIN_USAGE_LOCK" usage_refresh_all
}

# Kick a background refresh when the cache is stale. Never blocks: the caller
# decides on the sample it already has. A blocking curl on the Agent dispatch
# path would add latency to every delegation and stall on any network hiccup.
usage_ensure_fresh() {
  [ "$(usage_enforce)" = "off" ] && return 0
  local last now ttl
  now="$(date +%s)"
  ttl="$(usage_ttl)"
  last="$(cat "$BRAIN_USAGE_STAMP" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # Back off hard while the endpoint is failing, so a 404 becomes a trickle.
  [ -f "$BRAIN_USAGE_DIR/.last-error" ] && ttl=$(( ttl * 20 ))
  [ $((now - last)) -ge "$ttl" ] || return 0
  local brain
  brain="$(command -v brain 2>/dev/null || printf '%s' "$HOME/.local/bin/brain")"
  [ -x "$brain" ] || return 0
  run_detached "$brain" usage --refresh
  return 0
}

# "1h 24m" / "8m" / "" from the cached resets_in.
usage_reset_human() {
  local s; s="$(usage_field resets_in 2>/dev/null || echo 0)"
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  [ "$s" -gt 0 ] || return 1
  if [ "$s" -ge 3600 ]; then printf '%dh %dm\n' $((s / 3600)) $(((s % 3600) / 60))
  else printf '%dm\n' $(((s + 59) / 60))
  fi
}

# True when the agent spends the session's own Anthropic subscription. In the
# RC lane every non-brain-* agent does; brain-fable is Anthropic in either lane.
usage_agent_is_anthropic() {
  case "$1" in
    brain-fable)                              return 0 ;;
    brain-astra|brain-sol|brain-terra|brain-luna|brain-grok|brain-kimi) return 1 ;;
    brain-*)                                  return 1 ;;
    '')                                       return 1 ;;
    *)                                        return 0 ;;
  esac
}

# The routing decision for one Agent/Task dispatch.
#
# Prints "allow", or "advise" / "deny" followed by a message. Always exits 0 —
# the caller decides what to do with the verdict, and every uncertain path
# resolves to "allow". Blocking is only ever applied to Anthropic-backed
# subagents: the main thread has no PreToolUse event, so the session itself can
# never be cut off, and that is what makes the reserve safe.
usage_gate() {
  local agent="$1" state lanes headroom bind resets

  [ "$(usage_enforce)" = "off" ] && { printf 'allow\n'; return 0; }
  usage_agent_is_anthropic "$agent" || { printf 'allow\n'; return 0; }

  state="$(usage_state)"
  case "$state" in ok|unknown) printf 'allow\n'; return 0 ;; esac

  headroom="$(usage_field headroom 2>/dev/null || echo '?')"
  bind="$(usage_field bind 2>/dev/null || echo 'the current window')"
  resets="$(usage_reset_human 2>/dev/null || true)"
  lanes="$(usage_rank_lanes 2>/dev/null || true)"

  local where="Claude subscription at ${headroom}% headroom on ${bind}${resets:+, resets in $resets}"
  local alt="brain-astra / brain-sol / brain-grok / brain-terra / brain-kimi"
  # Name the alternative's actual headroom when we have it — "go use ChatGPT"
  # is far more persuasive with "it is at 98%" attached.
  local cx
  if cx="$(usage_codex_field headroom 2>/dev/null)" && [ "$(usage_codex_state)" != "critical" ]; then
    alt="brain-astra / brain-sol / brain-terra / brain-luna (ChatGPT is at ${cx}% headroom), or brain-grok / brain-kimi"
  fi

  if [ "$state" = "tight" ]; then
    printf 'advise\n'
    printf '%s. Prefer a consultant (%s) over an Anthropic-backed subagent, and do heavy implementation through one rather than in-session.\n' \
      "$where" "$alt"
    return 0
  fi

  # critical — the three safety valves, each of which downgrades to advisory.
  if usage_override_active; then
    printf 'advise\n'
    printf '%s — below the reserve, but an override is active, so this is allowed.\n' "$where"
    return 0
  fi
  if [ "$(usage_enforce)" != "block" ]; then
    printf 'advise\n'
    printf '%s — below the reserve. Enforcement is advisory, so this is allowed.\n' "$where"
    return 0
  fi
  if [ -z "$lanes" ]; then
    # Nowhere to send the work: blocking here would remove delegation entirely
    # with no alternative, which is strictly worse than spending the reserve.
    printf 'advise\n'
    printf '%s — below the reserve, but no consultant vendor is linked, so there is nowhere to offload. Allowing. Tell the user to run: brain auth chatgpt\n' "$where"
    return 0
  fi

  printf 'deny\n'
  printf "Blocked to preserve the Claude reserve: %s, which is at or below the %s%% reserve. '%s' would spend that reserve, and the reserve is what keeps this session able to answer.\nDo the work inline, or delegate to a consultant with headroom (linked: %s) — %s.\nIf you truly need it, tell the user they can run 'brain usage override 30' or 'brain config usage reserve 0'.\n" \
    "$where" "$(usage_reserve_pct)" "$agent" "$lanes" "$alt"
  return 0
}

# Advisory text is injected into the model's context, so an unlimited one would
# poison every window and burn the very quota it protects. Emit only when the
# band has changed, or after a 10-minute floor, and never at ok/unknown.
BRAIN_USAGE_ADVICE_FLOOR=600
usage_advice_due() {
  local state="$1" f="$BRAIN_USAGE_DIR/.last-advice" prev_state prev_at now
  case "$state" in tight|critical) ;; *) return 1 ;; esac
  now="$(date +%s)"
  if [ -f "$f" ]; then
    read -r prev_state prev_at < "$f" || true
    case "$prev_at" in ''|*[!0-9]*) prev_at=0 ;; esac
    if [ "$prev_state" = "$state" ] && [ $((now - prev_at)) -lt "$BRAIN_USAGE_ADVICE_FLOOR" ]; then
      return 1
    fi
  fi
  mkdir -p "$BRAIN_USAGE_DIR"
  printf '%s %s\n' "$state" "$now" > "$f"
  return 0
}

# Reason the last refresh failed, if any. Empty when the last fetch succeeded.
usage_last_error() {
  cat "$BRAIN_USAGE_DIR/.last-error" 2>/dev/null | cut -d' ' -f2- || true
}

# ---- ChatGPT / Codex headroom ----
#
# Codex reports usage only as `x-codex-*` response headers on a real POST to
# /backend-api/codex/responses. No GET carries them (models is a 400; usage and
# rate_limits sit behind a Cloudflare managed challenge), and our router does not
# forward upstream response headers to loopback clients. So the only way to read
# it is to make one minimal request ourselves.
#
# That request costs ~21 tokens (16 in / 5 out) against a weekly window, which is
# why it is on by default — but it IS the user's quota, so it gets its own longer
# TTL and `brain config usage probe off` switches it off entirely.
BRAIN_CODEX_STATE="$BRAIN_USAGE_DIR/codex.txt"
BRAIN_CODEX_STAMP="$BRAIN_USAGE_DIR/.last-codex"
BRAIN_CODEX_ENDPOINT="${BRAIN_CODEX_ENDPOINT:-https://chatgpt.com/backend-api/codex/responses}"
# Pinned to match the router's own codex client, so the request is not challenged.
BRAIN_CODEX_UA="codex-tui/0.135.0 (Mac OS 26.5.0; arm64) iTerm.app/3.6.10 (codex-tui; 0.135.0)"
BRAIN_CODEX_PROBE_MODEL="${BRAIN_CODEX_PROBE_MODEL:-gpt-5.6-luna}"

usage_probe_enabled() { [ "$(setting_get USAGE_PROBE on)" = "on" ]; }
usage_probe_ttl() {
  local t; t="$(setting_get USAGE_PROBE_TTL 900)"
  case "$t" in ''|*[!0-9]*) t=900 ;; esac
  [ "$t" -ge 120 ] || t=120
  printf '%s\n' "$t"
}

usage_codex_field() {
  [ -f "$BRAIN_CODEX_STATE" ] || return 1
  local v
  v="$(awk -v k="$1" '{for(i=1;i<=NF;i++){split($i,p,"=");if(p[1]==k){print p[2];exit}}}' \
    "$BRAIN_CODEX_STATE")" || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# Send one minimal turn and keep only the rate-limit headers it comes back with.
usage_refresh_codex() {
  usage_probe_enabled || return 1
  local rec tok acc hdr body now rc=0
  now="$(date +%s)"
  rec="$(ls "$BRAIN_AUTH_DIR"/codex-*.json 2>/dev/null | head -1)"
  [ -n "$rec" ] || return 1
  tok="$(jq -r '.access_token // empty' "$rec" 2>/dev/null || true)"
  acc="$(jq -r '.account_id // empty' "$rec" 2>/dev/null || true)"
  [ -n "$tok" ] || return 1

  hdr="$BRAIN_USAGE_DIR/.codex-hdr.$$"
  body="$BRAIN_USAGE_DIR/.codex-body.$$"
  if [ -n "${BRAIN_CODEX_FIXTURE:-}" ]; then
    cp "$BRAIN_CODEX_FIXTURE" "$hdr" 2>/dev/null || rc=1
  else
    # Header on stdin, never argv. A rejected model 400s *before* the rate-limit
    # middleware and carries no x-codex-* headers, so the turn has to be real.
    printf 'Authorization: Bearer %s\nChatgpt-Account-Id: %s\nOriginator: codex-tui\nUser-Agent: %s\nContent-Type: application/json\nAccept: text/event-stream\nOpenAI-Beta: responses=experimental\n' \
        "$tok" "$acc" "$BRAIN_CODEX_UA" \
      | curl -sS -m 30 -H @- -D "$hdr" -o "$body" \
          --data-binary "{\"model\":\"$BRAIN_CODEX_PROBE_MODEL\",\"instructions\":\"Reply with one character.\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}],\"stream\":true,\"store\":false,\"tools\":[],\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,\"reasoning\":{\"effort\":\"low\",\"summary\":\"auto\"},\"include\":[]}" \
          "$BRAIN_CODEX_ENDPOINT" >/dev/null 2>&1 || rc=$?
  fi
  rm -f "$body"
  printf '%s\n' "$now" > "$BRAIN_CODEX_STAMP"

  local primary secondary plan reset_after credits
  primary="$(sed -n 's/^[Xx]-[Cc]odex-primary-used-percent:[[:space:]]*//p'            "$hdr" 2>/dev/null | tr -d '\r' | head -1)"
  secondary="$(sed -n 's/^[Xx]-[Cc]odex-secondary-used-percent:[[:space:]]*//p'        "$hdr" 2>/dev/null | tr -d '\r' | head -1)"
  plan="$(sed -n 's/^[Xx]-[Cc]odex-plan-type:[[:space:]]*//p'                          "$hdr" 2>/dev/null | tr -d '\r' | head -1)"
  reset_after="$(sed -n 's/^[Xx]-[Cc]odex-primary-reset-after-seconds:[[:space:]]*//p' "$hdr" 2>/dev/null | tr -d '\r' | head -1)"
  credits="$(sed -n 's/^[Xx]-[Cc]odex-credits-has-credits:[[:space:]]*//p'             "$hdr" 2>/dev/null | tr -d '\r' | head -1)"
  rm -f "$hdr"

  case "$primary"   in ''|*[!0-9]*) return 1 ;; esac
  case "$secondary" in ''|*[!0-9]*) secondary=0 ;; esac
  [ "$primary" -le 100 ] && [ "$secondary" -le 100 ] || return 1
  case "$reset_after" in ''|*[!0-9]*) reset_after=0 ;; esac

  local used="$primary"
  [ "$secondary" -gt "$used" ] && used="$secondary"

  local tmp="$BRAIN_CODEX_STATE.tmp.$$"
  printf 'updated_at=%s headroom=%s primary=%s secondary=%s plan=%s resets_in=%s credits=%s\n' \
    "$now" "$((100 - used))" "$primary" "$secondary" "${plan:-unknown}" "$reset_after" \
    "$([ "$credits" = "True" ] && printf yes || printf no)" > "$tmp"
  mv "$tmp" "$BRAIN_CODEX_STATE"
  return 0
}

# ok | tight | critical | unknown for ChatGPT, on the same thresholds as Claude.
usage_codex_state() {
  local h updated now age
  h="$(usage_codex_field headroom 2>/dev/null || true)"
  updated="$(usage_codex_field updated_at 2>/dev/null || true)"
  case "$updated" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  case "$h" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  now="$(date +%s)"; age=$((now - updated))
  # The binding Codex window is weekly, so a sample stays meaningful far longer
  # than the Anthropic five-hour one.
  if [ "$age" -gt 86400 ] || [ "$age" -lt -300 ]; then printf 'unknown\n'; return 0; fi
  if   [ "$h" -le "$(usage_reserve_pct)" ];  then printf 'critical\n'
  elif [ "$h" -le "$(usage_advisory_pct)" ]; then printf 'tight\n'
  else printf 'ok\n'
  fi
}

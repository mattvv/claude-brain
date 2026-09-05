#!/usr/bin/env bash
# claude-brain PreToolUse hook (Agent/Task). Two guards, in order:
#
#  1. Vendor guard — block delegation to a brain-* agent whose backing vendor
#     isn't linked, with the exact fix, instead of letting the call fail
#     mid-task with a raw HTTP error. Modeled on parable's model_guard.
#
#  2. Usage guard — when the session's own Claude subscription is down to its
#     reserve, block Anthropic-backed subagents (Explore, Plan, general-purpose,
#     brain-fable, …) and point at a consultant with headroom instead. The main
#     thread has no PreToolUse event, so it is never affected: the reserve stays
#     available for the session to keep answering. brain-* consultants are never
#     usage-blocked — they are the escape hatch.
#
# Both guards fail open on anything unexpected.
#
# Exit 0 = allow, exit 2 = deny (stderr is shown to the model).

set -uo pipefail

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0   # never break dispatch if jq is missing

TOOL="$(jq -r '.tool_name // empty' <<<"$INPUT")"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

AGENT="$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT")"

AUTH_DIR="${BRAIN_AUTH_DIR:-$HOME/.cli-proxy-api}"

# ---- 1. vendor guard (brain-* only) ----
case "$AGENT" in
  brain-*)
    # agent -> credential-record prefix, auth command, human vendor name
    case "$AGENT" in
      brain-astra|brain-sol|brain-terra|brain-luna) prefix="codex"  cmd="chatgpt" vendor="ChatGPT" ;;
      brain-grok)                       prefix="xai"    cmd="grok"    vendor="Grok (X.AI)" ;;
      brain-kimi)                       prefix="kimi"   cmd="kimi"    vendor="Kimi" ;;
      brain-fable)                      prefix="claude" cmd="claude"  vendor="Claude (proxy vendor)" ;;
      *)                                prefix="" ;;
    esac

    # brain-fable only matters in the multi lane; in the RC lane the session's own
    # Claude login covers it and no proxy credential is involved.
    if [ "$AGENT" = "brain-fable" ] && [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
      prefix=""
    fi

    if [ -n "$prefix" ]; then
      found=0
      for f in "$AUTH_DIR/$prefix"-*.json; do
        [ -e "$f" ] && { found=1; break; }
      done
      if [ "$found" -eq 0 ]; then
        echo "Blocked: '$AGENT' needs a linked $vendor account, but none is connected on this brain. Tell the user to run 'brain auth $cmd' (over SSH) to link it, then use the next fallback in the routing table meanwhile." >&2
        exit 2
      fi
    fi
    ;;
esac

# ---- 2. usage guard (all agents; only Anthropic-backed ones can be denied) ----
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh" 2>/dev/null || exit 0

usage_ensure_fresh 2>/dev/null || true

VERDICT="$(usage_gate "$AGENT" 2>/dev/null)" || exit 0
MODE="$(printf '%s\n' "$VERDICT" | head -1)"
MSG="$(printf '%s\n' "$VERDICT" | tail -n +2)"

case "$MODE" in
  deny)
    printf '%s\n' "$MSG" >&2
    exit 2
    ;;
  advise)
    # Allow, but put the live numbers in front of the model at the exact moment
    # it is choosing where to send work. Rate-limited so it cannot spam context.
    if usage_advice_due "$(usage_state)" 2>/dev/null; then
      jq -nc --arg ctx "$MSG" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$ctx}}'
    fi
    exit 0
    ;;
esac

exit 0

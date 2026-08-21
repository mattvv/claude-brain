#!/usr/bin/env bash
# claude-brain PostToolUse hook: push a line to the USER after a tool call —
# consultation progress while a brain-* consult streams, and a subscription
# headroom warning when the Claude subscription is running low.
#
# This exists because Bash output goes to the model, not the user: in a Remote
# Control session a model that polls the consult log inside long Bash loops
# leaves the user staring at "running 1 task". `systemMessage` is the only
# channel that reaches the user without the model choosing to narrate.
#
# Paired with consult-poll-guard.sh, which stops the model from blocking so long
# that no PostToolUse event fires.
#
# Exit 0 always: a progress hook must never break a tool call.

set -uo pipefail

cat >/dev/null                                   # drain hook JSON on stdin
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh" 2>/dev/null || exit 0

# Keep the usage cache warm. This is the cheapest keep-warm surface we have —
# the hook already runs on every tool call, and the refresh is backgrounded.
usage_ensure_fresh 2>/dev/null || true

# Headroom notice. Checked BEFORE the consult early-exit below, because it must
# fire whether or not a consultation happens to be streaming. Rate-limited to
# band transitions plus a 10-minute floor: this text lands in the model's
# context, so an unlimited one would burn the very quota it protects.
usage_msg=""
u_state="$(usage_state 2>/dev/null || echo unknown)"
if usage_advice_due "$u_state" 2>/dev/null; then
  usage_headroom="$(usage_field headroom 2>/dev/null || echo '?')"
  usage_bind="$(usage_field bind 2>/dev/null || echo 'the current window')"
  if [ "$u_state" = "critical" ]; then
    usage_msg="Claude subscription down to ${usage_headroom}% headroom on ${usage_bind} — at the $(usage_reserve_pct)% reserve. Anthropic-backed subagents are blocked; send heavy work to a brain-* consultant or do it inline."
  else
    usage_msg="Claude subscription at ${usage_headroom}% headroom on ${usage_bind}. Prefer brain-* consultants for heavy work to preserve the reserve."
  fi
fi

line="$(consult_progress_line)" || line=""

# Nothing to say at all.
if [ -z "$line" ] && [ -z "$usage_msg" ]; then
  exit 0
fi

# Only a usage notice: emit it on its own and stop. A hook prints one object.
if [ -z "$line" ]; then
  jq -nc --arg msg "🪫 $usage_msg" --arg ctx "$usage_msg" \
    '{systemMessage: $msg,
      hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
  exit 0
fi

# Rate-limit: repeat an unchanged line at most once every 25s, so a burst of
# tool calls during one silent thinking phase does not spam the transcript.
stamp="$BRAIN_CONSULT_DIR/.last-progress"
now="$(date +%s)"
if [ -f "$stamp" ]; then
  prev_line="$(sed -n '2,$p' "$stamp")"
  prev_at="$(sed -n '1p' "$stamp")"
  if [ "$line" = "$prev_line" ] && [ $((now - ${prev_at:-0})) -lt 25 ]; then
    exit 0
  fi
fi
umask 077
{ printf '%s\n' "$now"; printf '%s\n' "$line"; } > "$stamp" 2>/dev/null || true

jq -nc --arg msg "🧠 $line${usage_msg:+  ·  🪫 $usage_msg}" --arg ctx \
  "A brain consultation is streaming: $line. The user has just been shown this line automatically. Keep polling in short increments and add your own one-line read of what the consultant is arguing — do not go silent, and do not block for minutes in a single Bash call.${usage_msg:+ Also: $usage_msg}" \
  '{systemMessage: $msg,
    hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
exit 0

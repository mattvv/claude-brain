#!/usr/bin/env bash
# claude-brain PostToolUse hook: while a brain-* consultation is streaming, push
# a progress line to the USER after every tool call.
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

line="$(consult_progress_line)" || exit 0
[ -n "$line" ] || exit 0

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

jq -nc --arg msg "🧠 $line" --arg ctx \
  "A brain consultation is streaming: $line. The user has just been shown this line automatically. Keep polling in short increments and add your own one-line read of what the consultant is arguing — do not go silent, and do not block for minutes in a single Bash call." \
  '{systemMessage: $msg,
    hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
exit 0

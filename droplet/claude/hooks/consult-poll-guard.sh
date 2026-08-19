#!/usr/bin/env bash
# claude-brain PreToolUse hook (Bash): while a brain-* consultation is streaming,
# refuse Bash calls that block for minutes.
#
# Rationale: consult-progress.sh can only push a line to the user when a tool
# call completes. A model that waits inside one long `for … sleep …` loop emits
# no events for the whole consultation, which is exactly how a 22-minute
# consult once reached the user as total silence. Forcing short polls keeps the
# progress events flowing.
#
# Exit 0 = allow, exit 2 = deny (stderr is shown to the model).

set -uo pipefail

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0        # never break dispatch

TOOL="$(jq -r '.tool_name // empty' <<<"$INPUT")"
[ "$TOOL" = "Bash" ] || exit 0

# Backgrounded commands return immediately; they never stall the progress loop.
[ "$(jq -r '.tool_input.run_in_background // .run_in_background // false' <<<"$INPUT")" = "true" ] && exit 0

CMD="$(jq -r '.tool_input.command // empty' <<<"$INPUT")"
[ -n "$CMD" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh" 2>/dev/null || exit 0

consult_active || exit 0                        # idle: no restrictions at all

deny() {
  cat >&2 <<MSG
Blocked while a brain consultation is streaming: $1

The user only sees consultation progress when a tool call completes, so a long
blocking wait makes the consult invisible to them. Instead:

  1. Poll once, briefly:  sleep 45; brain consult status
  2. Write a one-line progress update to the user in chat.
  3. Repeat.

Relay what the consultant is actually arguing as it appears — not just byte
counts. Use run_in_background:true for genuinely long-running work.
MSG
  exit 2
}

# A sleep inside a loop is the anti-pattern: the total wait is unbounded from
# the outside, and no PostToolUse event fires until the whole loop finishes.
if grep -qE '(^|[; &|(])(for|while|until)[ (]' <<<"$CMD" && grep -qE '(^|[; &|(])sleep ' <<<"$CMD"; then
  deny "a sleep inside a loop waits without reporting anything back."
fi

# A single oversized sleep has the same effect.
LONGEST="$(grep -oE '(^|[; &|(])sleep +[0-9]+' <<<"$CMD" | grep -oE '[0-9]+$' | sort -n | tail -1)"
if [ -n "${LONGEST:-}" ] && [ "$LONGEST" -gt 90 ]; then
  deny "'sleep $LONGEST' blocks for $((LONGEST / 60))m before the user hears anything."
fi

# Unbounded follow-mode tails never return on their own.
if grep -qE '\btail\b[^|;&]*[ ]-[a-zA-Z]*[fF]' <<<"$CMD" && ! grep -qE '\btimeout\b' <<<"$CMD"; then
  deny "'tail -f' without a timeout never returns."
fi

exit 0

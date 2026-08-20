#!/usr/bin/env bash
# claude-brain PreToolUse hook (Bash): reroute eligible verbose commands through
# `brain-compress shell` so their output reaches the model compact but fully
# recoverable. MUTATE-ONLY — it never denies, so it composes safely with the
# deny-only consult-poll-guard hook (at most one hook rewrites the command).
#
# All policy lives in the native binary; this is a thin, fail-open launcher.
# Exit 0 with no output = allow unchanged.
set -uo pipefail

BRAIN_DATA_DIR="${BRAIN_DATA_DIR:-$HOME/.local/share/brain}"
NATIVE="$BRAIN_DATA_DIR/native/current/brain-compress"

# No native binary installed → compression unavailable, allow unchanged.
[ -x "$NATIVE" ] || exit 0

exec "$NATIVE" hook pre-bash

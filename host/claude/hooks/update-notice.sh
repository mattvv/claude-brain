#!/usr/bin/env bash
# claude-brain SessionStart hook: tell a new session when claude-brain is behind
# origin/main, so an always-on brain (whose server starts with no terminal and
# never sees the prompt in check_for_updates) still learns about releases — and
# can offer to update itself from the phone.
#
# Reads the cached record only, then refreshes it in the background when stale;
# a session start never waits on the network. Exit 0 always.

set -uo pipefail

cat >/dev/null                                   # drain hook JSON on stdin
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh" 2>/dev/null || exit 0

behind="$(update_field behind 2>/dev/null || true)"
latest="$(update_field latest 2>/dev/null || true)"
update_check_maybe

case "${behind:-0}" in ''|*[!0-9]*|0) exit 0 ;; esac

label="${latest:+ ($latest)}"
jq -nc --arg msg "⬆ claude-brain update available$label — run: brain update" \
  --arg ctx "claude-brain is $behind change(s) behind its latest release$label. Tell the user once, early, and offer to run \`brain update\` for them; the new agents and routing apply to sessions started after it finishes." \
  '{systemMessage: $msg,
    hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0

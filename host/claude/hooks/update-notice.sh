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

# An unattended update (update_auto_maybe) finished since the last session: say
# so once, whatever the outcome, then forget it.
auto="$(dirname "$BRAIN_UPDATE_FILE")/auto-result"
if [ -r "$auto" ]; then
  result="$(awk 'NR==1{for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="result") print kv[2]}}' "$auto")"
  to="$(awk 'NR==1{for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="to") print kv[2]}}' "$auto")"
  rm -f "$auto"
  update_check_maybe
  if [ "$result" = ok ]; then
    msg="⬆ claude-brain updated itself${to:+ to $to}"
    ctx="claude-brain auto-updated itself${to:+ to $to} since the last session. Mention it to the user once."
  else
    msg="! claude-brain tried to update itself and failed — run: brain update"
    ctx="An unattended claude-brain update failed (log: $(dirname "$BRAIN_UPDATE_FILE")/auto.log). Tell the user once and offer to run \`brain update\` and report what it says."
  fi
  jq -nc --arg msg "$msg" --arg ctx "$ctx" \
    '{systemMessage: $msg,
      hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  exit 0
fi

update_check_maybe

case "${behind:-0}" in ''|*[!0-9]*|0) exit 0 ;; esac

label="${latest:+ ($latest)}"
jq -nc --arg msg "⬆ claude-brain update available$label — run: brain update" \
  --arg ctx "claude-brain is $behind change(s) behind its latest release$label. Tell the user once, early, and offer to run \`brain update\` for them; the new agents and routing apply to sessions started after it finishes." \
  '{systemMessage: $msg,
    hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0

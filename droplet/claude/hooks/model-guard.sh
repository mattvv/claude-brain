#!/usr/bin/env bash
# claude-brain PreToolUse hook (Agent/Task): block delegation to a brain-* agent
# whose backing vendor isn't linked, with the exact fix, instead of letting the
# call fail mid-task with a raw HTTP error. Modeled on parable's model_guard.
#
# Exit 0 = allow, exit 2 = deny (stderr is shown to the model).

set -uo pipefail

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0   # never break dispatch if jq is missing

TOOL="$(jq -r '.tool_name // empty' <<<"$INPUT")"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

AGENT="$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT")"
case "$AGENT" in brain-*) ;; *) exit 0 ;; esac

AUTH_DIR="${BRAIN_AUTH_DIR:-$HOME/.cli-proxy-api}"

# agent -> credential-record prefix, auth command, human vendor name
case "$AGENT" in
  brain-sol|brain-terra|brain-luna) prefix="codex"  cmd="chatgpt" vendor="ChatGPT" ;;
  brain-grok)                       prefix="xai"    cmd="grok"    vendor="Grok (X.AI)" ;;
  brain-kimi)                       prefix="kimi"   cmd="kimi"    vendor="Kimi" ;;
  brain-fable)                      prefix="claude" cmd="claude"  vendor="Claude (proxy vendor)" ;;
  *) exit 0 ;;
esac

# brain-fable only matters in the multi lane; in the RC lane the session's own
# Claude login covers it and no proxy credential is involved.
if [ "$AGENT" = "brain-fable" ] && [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
  exit 0
fi

found=0
for f in "$AUTH_DIR/$prefix"-*.json; do
  [ -e "$f" ] && { found=1; break; }
done

if [ "$found" -eq 0 ]; then
  echo "Blocked: '$AGENT' needs a linked $vendor account, but none is connected on this brain. Tell the user to run 'brain auth $cmd' (over SSH) to link it, then use the next fallback in the routing table meanwhile." >&2
  exit 2
fi

exit 0

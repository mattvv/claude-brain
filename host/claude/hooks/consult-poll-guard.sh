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

SESSION="$(jq -r '.session_id // empty' <<<"$INPUT")"
consult_active "$SESSION" || exit 0             # idle: no restrictions at all

deny() {
  cat >&2 <<MSG
Blocked while a brain consultation is streaming: $1

The user only sees consultation progress when a tool call completes, so a long
blocking wait makes the consult invisible to them. Instead:

  1. Poll once, briefly:  brain consult wait
  2. Write a one-line progress update to the user in chat.
  3. Repeat.

Relay what the consultant is actually arguing as it appears — not just byte
counts. Use run_in_background:true for genuinely long-running work.
MSG
  exit 2
}

# Judge only what the shell runs: a heredoc body is data (a file being written,
# a script fed to python), so its `while` and `sleep` words are not a wait.
# The terminator is the delimiter word with its quotes removed, `<<-` strips
# leading tabs, `<<<` is a here-string, `<<` inside quotes or a `#` comment
# opens nothing (a quoted delimiter like <<'EOF' is read first), and one line
# can open several heredocs, read in order. An unquoted heredoc still runs any
# $(...) or `...` in its body (which may span lines), so such a body is judged
# whole, as is any body fed to a shell (`bash <<'EOF'`). A "heredoc" whose terminator never comes is judged in full too.
SCAN="$(awk '
  # Remove quoted text, except quotes that belong to a heredoc delimiter word.
  function drop_quoted(text,    out, pre, rest, q, stop) {
    out = ""
    while (match(text, /["'"'"']/)) {
      q = substr(text, RSTART, 1)
      pre = substr(text, 1, RSTART - 1)
      rest = substr(text, RSTART + 1)
      stop = index(rest, q)
      if (stop == 0) { out = out text; return out }
      if (pre ~ /<<-?[ \t]*[^ \t;&|<>()]*$/) out = out pre q substr(rest, 1, stop)
      else out = out pre
      text = substr(rest, stop + 1)
    }
    return out text
  }
  function open_heredocs(text,    word, quoted, delim, before, runs) {
    gsub(/<<</, "", text)
    text = drop_quoted(text)
    sub(/(^|[ \t])#.*$/, "", text)
    while (match(text, /<<-?[ \t]*/)) {
      tabs = (substr(text, RSTART, 3) == "<<-")
      before = substr(text, 1, RSTART - 1)
      text = substr(text, RSTART + RLENGTH)
      # A shell reading the heredoc runs its body, quoted or not.
      runs = (before ~ /(^|[;&|( \t])(ba|z|da|k)?sh([ \t]+-[A-Za-z]+)*[ \t]*$/)
      if (match(text, /^"[^"]*"/) || match(text, /^'"'"'[^'"'"']*'"'"'/)) {
        word = substr(text, 1, RLENGTH)
      } else if (match(text, /^[^ \t;&|<>()]+/)) {
        word = substr(text, 1, RLENGTH)
      } else continue
      text = substr(text, RLENGTH + 1)
      quoted = (word ~ /["'"'"'\\]/)
      delim = word
      gsub(/["'"'"'\\]/, "", delim)
      pending[++npending] = delim; ptabs[npending] = tabs; pquoted[npending] = quoted; pruns[npending] = runs
    }
  }
  npending > 0 {
    line = $0
    if (ptabs[1]) sub(/^\t+/, "", line)
    if (line == pending[1]) {
      if (subst) printf "%s", held
      held = ""; subst = 0
      for (i = 1; i < npending; i++) { pending[i] = pending[i + 1]; ptabs[i] = ptabs[i + 1]; pquoted[i] = pquoted[i + 1]; pruns[i] = pruns[i + 1] }
      npending--
      next
    }
    held = held $0 "\n"
    if (pruns[1] || (!pquoted[1] && (line ~ /\$\(/ || line ~ /`/))) subst = 1
    next
  }
  { print; open_heredocs($0) }
  END { if (npending > 0) printf "%s", held }' <<<"$CMD")"

# A sleep inside a loop is the anti-pattern: the total wait is unbounded from
# the outside, and no PostToolUse event fires until the whole loop finishes.
if grep -qE '(^|[; &|(])(for|while|until)[ (]' <<<"$SCAN" && grep -qE '(^|[; &|(])sleep ' <<<"$SCAN"; then
  deny "a sleep inside a loop waits without reporting anything back."
fi

# A single oversized sleep has the same effect.
LONGEST="$(grep -oE '(^|[; &|(])sleep +[0-9]+' <<<"$SCAN" | grep -oE '[0-9]+$' | sort -n | tail -1)"
if [ -n "${LONGEST:-}" ] && [ "$LONGEST" -gt 90 ]; then
  deny "'sleep $LONGEST' blocks for $((LONGEST / 60))m before the user hears anything."
fi

# Unbounded follow-mode tails never return on their own.
if grep -qE '\btail\b[^|;&]*[ ]-[a-zA-Z]*[fF]' <<<"$SCAN" && ! grep -qE '\btimeout\b' <<<"$SCAN"; then
  deny "'tail -f' without a timeout never returns."
fi

exit 0

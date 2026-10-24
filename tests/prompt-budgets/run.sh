#!/usr/bin/env bash
# The managed CLAUDE.md blocks are loaded into every session and every subagent,
# so the part of each block that goes inline (everything above the
# `claude-brain:more` marker) has a size budget. Budgets are in bytes, at
# roughly four bytes per token; raise one only alongside a reason in the commit.
#
#   tests/prompt-budgets/run.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd -P "$HERE/../../host/claude" && pwd)"
PASS=0; FAIL=0

inline_bytes() {
  awk '/^<!-- claude-brain:more -->$/{exit} {print}' "$1" | wc -c | tr -d ' '
}

budget() {
  local file="$1" max_bytes="$2" actual_bytes
  actual_bytes="$(inline_bytes "$SRC/$file")"
  if [ "$actual_bytes" -le "$max_bytes" ]; then
    PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s inline %s <= %s bytes\n' "$file" "$actual_bytes" "$max_bytes"
  else
    FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s inline %s > %s bytes\n' "$file" "$actual_bytes" "$max_bytes"
  fi
}

# ops carries the safety rules plus a placeholder scope note of ~250 bytes.
budget brain-ops-local.md   1400
budget brain-ops-droplet.md 1400
budget routing-rc.md        2800
budget routing-multi.md     2800
budget usage-policy.md      1000
budget consult-background.md 1000
budget consult-foreground.md 1000
budget pstack-mode.md       1400

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

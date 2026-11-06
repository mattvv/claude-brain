#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/cursor-agent" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BRAIN_CURSOR_TEST_ARGS"
printf 'Cursor answer\n'
MOCK
chmod +x "$WORK/bin/cursor-agent"
printf 'first\nsecond\nthird\n' > "$WORK/context.txt"

export PATH="$WORK/bin:$PATH"
export BRAIN_CURSOR_TEST_ARGS="$WORK/args"
output="$("$ROOT/host/libexec/brain-cursor-ask" cursor:gemini-4-argon-high \
  --context-range "$WORK/context.txt@2:3" 'Review this change')"
[ "$output" = 'Cursor answer' ]
grep -Fxq -- '--mode' "$WORK/args"
grep -Fxq -- 'ask' "$WORK/args"
grep -Fxq -- '--model' "$WORK/args"
grep -Fxq -- '--trust' "$WORK/args"
grep -Fxq -- 'gemini-4-argon-high' "$WORK/args"
grep -Fq -- 'second' "$WORK/args"
grep -Fq -- 'third' "$WORK/args"
! grep -Fq -- 'first' "$WORK/args"

"$ROOT/host/libexec/brain-cursor-ask" cursor:muse-wonder-1.0-high \
  --context-file "$WORK/context.txt" 'Review this change' >/dev/null
grep -Fxq -- 'muse-wonder-1.0-high' "$WORK/args"
grep -Fq -- 'first' "$WORK/args"

if "$ROOT/host/libexec/brain-cursor-ask" cursor:gemini-4-argon-high \
  --context-file "$WORK/missing" 'Review' >/dev/null 2>&1; then
  echo 'missing context file was accepted' >&2
  exit 1
fi

echo 'cursor-ask tests passed'

#!/usr/bin/env bash
# Frozen-corpus A/B runner (compression plan §5.3).
#
# Sends every fixture in tests/compress/ab/fixtures/ twice against ONE model:
#   control — context files inlined into the prompt, no response profile
#             (what an unguarded bridge would send)
#   guarded — the same material via --context-file, plus --response <profile>
# in randomized order, then reads provider ground-truth usage back out of the
# ledger and reports paired median deltas with bootstrap confidence intervals.
#
#   AB_MODEL=grok-4.5 tests/compress/ab/run-ab.sh
#
# Environment:
#   AB_MODEL    model to test (default grok-4.5; a Claude model is refused —
#               the Claude subscription is rate-limited and must not be spent)
#   AB_REPS     repetitions of the whole corpus (default 1)
#   AB_SLEEP    seconds between calls (default 2; use 0 against the fake proxy)
#   AB_BIN      brain-compress binary (default: the crate's debug build)
#   AB_RESULTS  results directory (default tests/compress/ab/results/<stamp>)
#   BRAIN_STATE_DIR  defaults to $AB_RESULTS/state so the experiment's ledger
#               stays separate from the live one. Afterwards,
#               BRAIN_STATE_DIR=<results>/state brain compress savings
#               shows the same ground truth through the normal CLI.
#
# Accounting honesty: everything this harness reports is the provider
# ground-truth class (usage fields from the response). It never mixes in
# measured bytes or estimated tokens, and never prints dollars.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE="$HERE/../../../droplet/native/brain-compress"
FIXTURES="$HERE/fixtures"

AB_MODEL="${AB_MODEL:-grok-4.5}"
AB_REPS="${AB_REPS:-1}"
AB_SLEEP="${AB_SLEEP:-2}"
AB_RESULTS="${AB_RESULTS:-$HERE/results/$(date +%Y%m%d-%H%M%S)}"
export BRAIN_STATE_DIR="${BRAIN_STATE_DIR:-$AB_RESULTS/state}"

case "$AB_MODEL" in
  *claude*|*sonnet*|*opus*|*haiku*|*fable*)
    echo "run-ab: refusing to run the A/B against a Claude-family model ($AB_MODEL)" >&2
    exit 2 ;;
esac

if [ -n "${AB_BIN:-}" ]; then
  BIN="$AB_BIN"
else
  BIN="$CRATE/target/debug/brain-compress"
  if [ ! -x "$BIN" ]; then
    echo "run-ab: building brain-compress (debug)..." >&2
    ( cd "$CRATE" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet )
  fi
fi

mkdir -p "$AB_RESULTS" "$BRAIN_STATE_DIR"
RESULTS_JSONL="$AB_RESULTS/results.jsonl"
LEDGER="$BRAIN_STATE_DIR/compress/ledger.jsonl"
if [ -z "${AB_TASKS_FILE:-}" ]; then
  : > "$RESULTS_JSONL"
else
  touch "$RESULTS_JSONL"
fi

# Build the randomized task list: fixture x rep x arm. AB_TASKS_FILE overrides
# it (used to resume an interrupted run: pass the not-yet-done tail of the
# original tasks.txt; result rows append to the existing results.jsonl).
TASKS="$AB_RESULTS/tasks.txt"
if [ -n "${AB_TASKS_FILE:-}" ]; then
  cp "$AB_TASKS_FILE" "$TASKS"
else
  : > "$TASKS"
  for rep in $(seq 1 "$AB_REPS"); do
    for dir in "$FIXTURES"/*/; do
      name="$(basename "$dir")"
      [ -f "$dir/fixture.json" ] || continue
      echo "$name $rep control" >> "$TASKS"
      echo "$name $rep guarded" >> "$TASKS"
    done
  done
  shuf "$TASKS" -o "$TASKS"
fi
TOTAL="$(wc -l < "$TASKS")"
if [ "$TOTAL" -eq 0 ]; then
  echo "run-ab: no fixtures found under $FIXTURES" >&2
  exit 2
fi

echo "run-ab: model=$AB_MODEL tasks=$TOTAL results=$AB_RESULTS"

INDEX=0
while read -r name rep arm; do
  INDEX=$((INDEX + 1))
  dir="$FIXTURES/$name"

  # fixture.json: {"category": ..., "profile": ..., "prompt": ..., "context": [...]}
  mapfile -t META < <(python3 -c '
import json, sys
f = json.load(open(sys.argv[1]))
print(f["category"]); print(f["profile"]); print(f["prompt"])
for c in f.get("context", []):
    print(c)' "$dir/fixture.json")
  category="${META[0]}"
  profile="${META[1]}"
  promptfile="${META[2]}"
  ctx=("${META[@]:3}")

  # Assemble the prompt for this arm. Control inlines the context bytes the way
  # an unguarded bridge would paste them; guarded passes paths so brain-ask
  # builds its context pack natively. Both arms see identical source material.
  PROMPTF="$AB_RESULTS/prompt.tmp"
  cp "$dir/$promptfile" "$PROMPTF"
  ARGS=()
  if [ "$arm" = "control" ]; then
    for c in "${ctx[@]:-}"; do
      [ -n "$c" ] || continue
      { printf '\n--- FILE: %s ---\n' "$c"; cat "$dir/$c"; } >> "$PROMPTF"
    done
  else
    ARGS+=(--response "$profile")
    for c in "${ctx[@]:-}"; do
      [ -n "$c" ] || continue
      ARGS+=(--context-file "$dir/$c")
    done
  fi

  if [ -f "$LEDGER" ]; then BEFORE="$(wc -l < "$LEDGER")"; else BEFORE=0; fi

  # ${ARGS[@]+...} expands to nothing (not an empty word) when ARGS is empty.
  "$BIN" ask "$AB_MODEL" ${ARGS[@]+"${ARGS[@]}"} - < "$PROMPTF" \
    > "$AB_RESULTS/last-answer.txt" 2> "$AB_RESULTS/last-stderr.txt" && RC=0 || RC=$?

  # Correlate the call with its ledger entry and record one result row. The
  # usage recorded here is exactly what the provider reported — no estimates.
  python3 -c '
import json, sys
ledger, before, fixture, category, rep, arm, rc = sys.argv[1:8]
row = {"fixture": fixture, "category": category, "rep": int(rep),
       "arm": arm, "exit": int(rc)}
try:
    lines = open(ledger).read().splitlines()[int(before):]
except OSError:
    lines = []
consults = []
for line in lines:
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get("event_kind") == "consult":
        consults.append(entry)
if consults:
    entry = consults[-1]
    usage = entry.get("usage", {})
    row.update({
        "ledger_arm": entry.get("arm"),
        "success": entry.get("success"),
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "latency_ms": entry.get("latency_ms"),
        "stop_reason": entry.get("stop_reason"),
        "provider_model": entry.get("provider_model"),
    })
print(json.dumps(row))' \
    "$LEDGER" "$BEFORE" "$name" "$category" "$rep" "$arm" "$RC" >> "$RESULTS_JSONL"

  echo "  [$INDEX/$TOTAL] $name rep=$rep $arm exit=$RC"
  [ "$AB_SLEEP" != "0" ] && sleep "$AB_SLEEP"
done < "$TASKS"
rm -f "$AB_RESULTS/prompt.tmp"

echo
python3 "$HERE/analyze.py" "$RESULTS_JSONL" | tee "$AB_RESULTS/report.txt"
echo
echo "run-ab: per-arm ground truth via the normal CLI:"
echo "  BRAIN_STATE_DIR=$BRAIN_STATE_DIR $BIN compress savings"

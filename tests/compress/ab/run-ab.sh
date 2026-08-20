#!/usr/bin/env bash
# Frozen-corpus A/B runner (compression plan §5.3).
#
# Sends every fixture in tests/compress/ab/fixtures/ once per VARIANT against
# ONE model, in randomized order, then reads provider ground-truth usage back
# out of the ledger and reports paired median deltas with bootstrap CIs.
#
# Default variants (identical to the original two-arm design):
#   control — context files inlined into the prompt, no extra flags
#             (what an unguarded bridge would send)
#   guarded — the same material via --context-file, plus --response <profile>
#
# AB_VARIANTS_FILE overrides them: a TSV of `name<TAB>brain-ask args`, where
# an EMPTY args column means control-style (inline context, no flags) and any
# non-empty args mean guarded-style (--context-file + those args). The token
# {profile} in args expands to the fixture's own response profile, e.g.:
#   control
#   guarded	--response {profile}
#   guard-low	--response {profile} --effort low
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
#   AB_FIXTURES space-separated globs selecting a fixture subset (default all)
#   AB_VARIANTS_FILE  variant TSV as above (default: control+guarded)
#   AB_TASKS_FILE     resume an interrupted run: pass the not-yet-done tail of
#               the original tasks.txt; result rows append instead of truncate
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
CRATE="$HERE/../../../host/native/brain-compress"
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

# Variant table: name -> args template.
declare -A VARIANTS
VARIANT_ORDER=()
if [ -n "${AB_VARIANTS_FILE:-}" ]; then
  while IFS=$'\t' read -r vname vargs; do
    vname="${vname%%[[:space:]]*}"
    [ -n "$vname" ] || continue
    case "$vname" in \#*) continue ;; esac
    VARIANTS["$vname"]="$vargs"
    VARIANT_ORDER+=("$vname")
  done < "$AB_VARIANTS_FILE"
  if [ "${#VARIANT_ORDER[@]}" -lt 2 ]; then
    echo "run-ab: AB_VARIANTS_FILE needs at least two variants" >&2
    exit 2
  fi
else
  VARIANTS[control]=""
  VARIANTS[guarded]="--response {profile}"
  VARIANT_ORDER=(control guarded)
fi

# Build the randomized task list: fixture x rep x variant. AB_TASKS_FILE
# overrides it (resume support).
TASKS="$AB_RESULTS/tasks.txt"
if [ -n "${AB_TASKS_FILE:-}" ]; then
  cp "$AB_TASKS_FILE" "$TASKS"
else
  : > "$TASKS"
  for rep in $(seq 1 "$AB_REPS"); do
    for dir in "$FIXTURES"/*/; do
      name="$(basename "$dir")"
      [ -f "$dir/fixture.json" ] || continue
      if [ -n "${AB_FIXTURES:-}" ]; then
        keep=0
        for pattern in $AB_FIXTURES; do
          case "$name" in $pattern) keep=1 ;; esac
        done
        [ "$keep" = 1 ] || continue
      fi
      for vname in "${VARIANT_ORDER[@]}"; do
        echo "$name $rep $vname" >> "$TASKS"
      done
    done
  done
  shuf "$TASKS" -o "$TASKS"
fi
TOTAL="$(wc -l < "$TASKS")"
if [ "$TOTAL" -eq 0 ]; then
  echo "run-ab: no fixtures matched under $FIXTURES" >&2
  exit 2
fi

echo "run-ab: model=$AB_MODEL variants=${VARIANT_ORDER[*]} tasks=$TOTAL results=$AB_RESULTS"

INDEX=0
while read -r name rep variant; do
  INDEX=$((INDEX + 1))
  dir="$FIXTURES/$name"
  if [ -z "${VARIANTS[$variant]+x}" ]; then
    echo "run-ab: unknown variant '$variant' in task list" >&2
    exit 2
  fi

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

  vargs_template="${VARIANTS[$variant]}"
  vargs="${vargs_template//\{profile\}/$profile}"

  # Assemble the prompt for this variant. Empty args = control-style: inline
  # the context bytes the way an unguarded bridge would paste them. Non-empty
  # args = guarded-style: pass paths so brain-ask builds its context pack
  # natively. Both styles see identical source material.
  PROMPTF="$AB_RESULTS/prompt.tmp"
  cp "$dir/$promptfile" "$PROMPTF"
  ARGS=()
  if [ -z "$vargs" ]; then
    expected_arm=control
    for c in "${ctx[@]:-}"; do
      [ -n "$c" ] || continue
      { printf '\n--- FILE: %s ---\n' "$c"; cat "$dir/$c"; } >> "$PROMPTF"
    done
  else
    read -r -a ARGS <<< "$vargs"
    # The ledger marks a call guarded only when a known --response profile is
    # present; mirror that so the arm-consistency check stays meaningful.
    case " $vargs " in
      *" --response "*) expected_arm=guarded ;;
      *) expected_arm=control ;;
    esac
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
ledger, before, fixture, category, rep, arm, variant, rc = sys.argv[1:9]
row = {"fixture": fixture, "category": category, "rep": int(rep),
       "arm": arm, "variant": variant, "exit": int(rc)}
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
    "$LEDGER" "$BEFORE" "$name" "$category" "$rep" "$expected_arm" "$variant" "$RC" >> "$RESULTS_JSONL"

  echo "  [$INDEX/$TOTAL] $name rep=$rep $variant exit=$RC"
  [ "$AB_SLEEP" != "0" ] && sleep "$AB_SLEEP"
done < "$TASKS"
rm -f "$AB_RESULTS/prompt.tmp"

echo
python3 "$HERE/analyze.py" "$RESULTS_JSONL" --compare "${VARIANT_ORDER[0]}" "${VARIANT_ORDER[1]}" \
  | tee "$AB_RESULTS/report.txt"
echo
echo "run-ab: per-arm ground truth via the normal CLI:"
echo "  BRAIN_STATE_DIR=$BRAIN_STATE_DIR $BIN compress savings"

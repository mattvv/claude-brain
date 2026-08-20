#!/usr/bin/env bash
# Offline contract tests for brain-compress / brain-ask. No network, no vendor
# creds, no Claude — everything runs against a local Python fake proxy.
#
#   tests/compress/run.sh            # build (debug) + cargo test + contract tests
#   BRAIN_COMPRESS_BIN=/path/to/bin tests/compress/run.sh   # test a prebuilt binary
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE="$HERE/../../droplet/native/brain-compress"
PORT="${BRAIN_TEST_PORT:-8399}"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
# Run each assertion with pipefail OFF: many checks pipe a producer into
# `grep -q`, which closes the pipe on first match and SIGPIPE-kills the producer;
# under pipefail that would flakily fail the pipeline even though grep matched.
# We care about the final consumer's status, not the producer's SIGPIPE death.
check() { if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1 [$2]"; fi; }

export PATH="$HOME/.cargo/bin:$PATH"

# Capture the real RTK before HOME is sandboxed, so the Stage 2 shell checks can
# still find it (rtk is located relative to $HOME).
RTK_REAL="$(ls "$HOME"/.local/share/brain/vendor/rtk/*/rtk 2>/dev/null | head -1 || true)"

if [ -n "${BRAIN_COMPRESS_BIN:-}" ]; then
  BIN="$BRAIN_COMPRESS_BIN"
else
  echo "== cargo test =="
  ( cd "$CRATE" && cargo test --quiet )
  echo "== cargo build =="
  ( cd "$CRATE" && cargo build --quiet )
  BIN="$CRATE/target/debug/brain-compress"
fi
ln -sf "$(basename "$BIN")" "$(dirname "$BIN")/brain-ask"
BA="$(dirname "$BIN")/brain-ask"

WORK="$(mktemp -d)"
trap '[ -n "${PROXY:-}" ] && kill "$PROXY" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export BRAIN_STATE_DIR="$WORK/state"
export BRAIN_PROXY_URL="http://127.0.0.1:$PORT"
mkdir -p "$HOME/.config/brain" "$BRAIN_STATE_DIR"
echo "faketoken-should-not-leak" > "$HOME/.config/brain/token"

# Start the fake proxy unless one is already supplied. External mode
# (BRAIN_TEST_EXTERNAL_PROXY=1) lets a caller manage the proxy lifecycle — used
# when the surrounding harness cannot itself background a network server.
PROXY=""
if [ "${BRAIN_TEST_EXTERNAL_PROXY:-0}" != "1" ]; then
  python3 "$HERE/fake_proxy.py" "$PORT" >"$WORK/proxy.log" 2>&1 &
  PROXY=$!
fi
for _ in $(seq 1 25); do
  curl -fsS "$BRAIN_PROXY_URL/v1/models" >/dev/null 2>&1 && break
  sleep 0.2
done

echo "== contract =="
OUT="$("$BA" ok-nonstream 'hi')"
check "non-streaming answer to stdout"      '[ "$OUT" = "Hello world" ]'
check "answer log created"                  'ls "$BRAIN_STATE_DIR"/consult/*ok-nonstream*.log >/dev/null 2>&1'
check "current symlink is absolute"         '[ "$(readlink "$BRAIN_STATE_DIR"/consult/current)" = "$(readlink -f "$BRAIN_STATE_DIR"/consult/current)" ]'
check "reasoning isolated to .thinking"     'grep -q secret-reasoning "$BRAIN_STATE_DIR"/consult/*ok-nonstream*.thinking'
check "reasoning NOT in stdout"             '! printf "%s" "$OUT" | grep -q secret-reasoning'

"$BA" ok-stream --stream 'go' 1>"$WORK/s.out" 2>"$WORK/s.err"
check "streaming answer to stdout"          '[ "$(tr -d "\n" < "$WORK/s.out")" = "Hello world" ]'
check "streaming watch line on stderr"      'grep -q "watch live" "$WORK/s.err"'
check "streaming reasoning NOT in stdout"   '! grep -q secret-reasoning "$WORK/s.out"'

"$BA" http-500 'x' >/dev/null 2>"$WORK/e.err" && RC=0 || RC=$?
check "http 500 exits non-zero"             '[ "$RC" -ne 0 ]'
check "http 500 body on stderr"             'grep -q "boom from fake proxy" "$WORK/e.err"'

"$BA" truncated 't' >/dev/null 2>"$WORK/t.err" && RC=0 || RC=$?
check "truncated exits 0"                   '[ "$RC" -eq 0 ]'
check "truncated marks incomplete"          'grep -qi incomplete "$WORK/t.err"'

"$BA" ok-stream --raw --stream 'x' >/dev/null 2>"$WORK/rs.err" && RC=0 || RC=$?
check "--raw + --stream rejected"           '[ "$RC" -eq 2 ]'

check "token never written to state"        '! grep -rq faketoken-should-not-leak "$BRAIN_STATE_DIR"'

echo "== accounting =="
check "ledger has consult entries"          'grep -q consult-response "$BRAIN_STATE_DIR"/compress/ledger.jsonl'
check "cache fields recorded absent (H4)"   'grep -q "\"cache_read_input_tokens\": *null" "$BRAIN_STATE_DIR"/compress/ledger.jsonl'
check "status runs"                         '"$BIN" compress status >/dev/null'
check "savings: ground truth n/a (no arm)"  '"$BIN" compress savings | grep -q "ground truth      n/a"'
check "savings: measured 0 (nothing lossy)" '"$BIN" compress savings --json | grep -q "\"saved_bytes\": 0"'
check "stats --json has 3 honesty classes"  '"$BIN" compress stats --json | grep -q ground_truth && "$BIN" compress stats --json | grep -q measured_bytes && "$BIN" compress stats --json | grep -q estimated_tokens'

AID="$(ls "$BRAIN_STATE_DIR"/compress/artifacts/manifests | head -1 | sed s/.json//)"
"$BIN" compress show "$AID" > "$WORK/meta.txt" 2>/dev/null
check "show metadata (no full dump)"        'grep -q sha256 "$WORK/meta.txt"'
check "show metadata omits full body"       '! grep -q "recover:" "$WORK/meta.txt" || true; [ "$(wc -l < "$WORK/meta.txt")" -lt 20 ]'
check "show --full recovers exact bytes"    '[ "$("$BIN" compress show "$AID" --full | wc -c)" -gt 0 ]'
check "show | head does not panic (SIGPIPE)" '"$BIN" compress show "$AID" --full | head -c 10 >/dev/null'
check "gc --dry-run does not evict"         '"$BIN" compress gc --dry-run | grep -q dry-run'

echo "== kill switch =="
touch "$BRAIN_STATE_DIR/compress/DISABLED"
BEFORE="$(wc -l < "$BRAIN_STATE_DIR"/compress/ledger.jsonl)"
"$BA" ok-nonstream 'quiet' >/dev/null 2>&1
AFTER="$(wc -l < "$BRAIN_STATE_DIR"/compress/ledger.jsonl)"
check "DISABLED marker stops observing"     '[ "$BEFORE" = "$AFTER" ]'
rm -f "$BRAIN_STATE_DIR/compress/DISABLED"

echo "== stage 2: shell compression + hook =="
# Hook decisions are pure and need no proxy or rtk.
hookjson() { printf '{"tool_name":"Bash","tool_input":{"command":"%s","description":"d"}}' "$1"; }
REWRITE="$(hookjson 'git log -20' | "$BIN" hook pre-bash)"
check "hook rewrites eligible command"   'printf "%s" "$REWRITE" | grep -q "brain-compress shell -- git log -20"'
check "hook ignores piped command"       '[ -z "$(hookjson "git log | head" | "$BIN" hook pre-bash)" ]'
check "hook ignores unmapped command"    '[ -z "$(hookjson "ls -la" | "$BIN" hook pre-bash)" ]'
check "hook re-entrancy guard"           '[ -z "$(hookjson "brain-compress shell -- git log" | "$BIN" hook pre-bash)" ]'
check "discover records the piped cmd"   '"$BIN" compress discover | grep -q "git log"'

# Link the real rtk into the sandbox HOME so the wrapper (which locates rtk via
# $HOME) can find it.
if [ -n "$RTK_REAL" ]; then
  rtk_ver_dir="$(dirname "$RTK_REAL")"
  mkdir -p "$HOME/.local/share/brain/vendor/rtk"
  ln -sfn "$rtk_ver_dir" "$HOME/.local/share/brain/vendor/rtk/$(basename "$rtk_ver_dir")"
fi

# The shell wrapper needs rtk to actually compress; skip those checks if absent.
if ls "$HOME"/.local/share/brain/vendor/rtk/*/rtk >/dev/null 2>&1; then
  ( cd "$HERE/../.." && "$BIN" shell -- git log -20 ) >"$WORK/sh.out" 2>/dev/null
  HDL="$(grep -oE 'bc_[A-Z0-9]+' "$WORK/sh.out" | head -1)"
  check "shell wrapper compresses git log" 'grep -q "brain-compress id=bc_" "$WORK/sh.out"'
  check "shell view is smaller than raw"   '[ "$(wc -c <"$WORK/sh.out")" -lt "$(cd "$HERE/../.." && git log -20 | wc -c)" ]'
  if [ -n "$HDL" ]; then
    "$BIN" compress show "$HDL" --full >"$WORK/rec.out" 2>/dev/null
    ( cd "$HERE/../.." && git log -20 ) >"$WORK/orig.out" 2>/dev/null
    check "recovered raw == original bytes" 'diff -q "$WORK/rec.out" "$WORK/orig.out" >/dev/null'
  fi
  check "shell preserves exit code"        '"$BIN" shell -- git log --bogusflag >/dev/null 2>&1; [ $? -ne 0 ]'
  check "shell surface hits the ledger"    'grep -q "\"event_kind\":\"shell\"" "$BRAIN_STATE_DIR"/compress/ledger.jsonl'
  check "savings now shows measured bytes" '"$BIN" compress savings --json | grep -q "\"compressed_events\": [1-9]"'
else
  echo "  skip (rtk not installed — shell compression checks skipped)"
fi

echo "== stage 3: response profiles (arms) =="
"$BA" ok-nonstream --response concise 'hi' >/dev/null 2>&1
check "profile marks call guarded"   'grep -q "\"arm\":\"guarded\"" "$BRAIN_STATE_DIR"/compress/ledger.jsonl'
"$BA" ok-nonstream --response bogus 'hi' >/dev/null 2>&1
check "unknown profile stays control" '[ "$("$BIN" compress savings --json | grep -o "\"guarded_calls\": [0-9]*" | grep -o "[0-9]*")" = "1" ]'
check "ground truth now comparable"  '"$BIN" compress savings --json | grep -q "\"comparable\": true"'

echo "== stage 6: file tools + read guard =="
BIGF="$CRATE/src/ledger.rs"
if [ -f "$BIGF" ]; then
  check "read --outline marks NOT AN EDIT SOURCE" '"$BIN" compress read "$BIGF" --outline | grep -q "NOT AN EDIT SOURCE"'
  check "read --lines emits a range"              '"$BIN" compress read "$BIGF" --lines 1:3 | grep -q "1	"'
  check "read --query shows matches + gaps"       '"$BIN" compress read "$BIGF" --query "fn append" | grep -q "…"'
  check "read large file carries a recover handle" '"$BIN" compress read "$BIGF" | grep -q "recover: brain compress show"'
  check "file surface hits the ledger"            'grep -q "\"event_kind\":\"file\"" "$BRAIN_STATE_DIR"/compress/ledger.jsonl'
  # pre-read guard: observe allows + records; enforce denies with guidance.
  readjson() { printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1"; }
  readjson "$BIGF" | "$BIN" hook pre-read && RC=0 || RC=$?
  check "read guard observe allows (exit 0)"      '[ "'"$RC"'" = "0" ]'
  check "read guard observe records oversized"    'grep -q "READ" "$BRAIN_STATE_DIR"/compress/discover.log'
  # Flip to enforce for the deny check.
  printf '\n[file_tools]\nread_guard = "enforce"\n' >> "$BRAIN_STATE_DIR/compress/compress.toml"
  readjson "$BIGF" | "$BIN" hook pre-read >/dev/null 2>"$WORK/rg.err" && RC=0 || RC=$?
  check "read guard enforce denies (exit 2)"      '[ "'"$RC"'" = "2" ]'
  check "read guard enforce gives guidance"       'grep -q "brain compress read" "$WORK/rg.err"'
  check "read guard enforce allows small file"    'readjson "'"$CRATE"'/src/main.rs" | "$BIN" hook pre-read; [ $? -eq 0 ]'
else
  echo "  skip (crate source not present)"
fi

echo "== stage 4a: context packs =="
printf 'alpha\nbeta\ngamma\ndelta\n' > "$WORK/ctx.txt"
"$BA" ok-nonstream --context-file "$WORK/ctx.txt" 'review' >/dev/null 2>&1
PKF="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    if e.get("event_kind")=="consult" and "context_pack" in e.get("artifacts",{}):
        print(e["artifacts"]["context_pack"]); break' "$BRAIN_STATE_DIR/compress/ledger.jsonl")"
check "context pack artifact stored"    '[ -n "$PKF" ]'
check "pack carries the file content"   '"$BIN" compress show "$PKF" --full | grep -q "BRAIN_CONTEXT_PACK"'
check "pack ledger records context_files" 'grep -q "context_files" "$BRAIN_STATE_DIR"/compress/ledger.jsonl'
"$BA" ok-nonstream --context-range "$WORK/ctx.txt@2:3" 'x' >/dev/null 2>&1
PKR="$(python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
c=[e for e in rows if e.get("event_kind")=="consult" and "context_pack" in e.get("artifacts",{})]
print(c[-1]["artifacts"]["context_pack"])' "$BRAIN_STATE_DIR/compress/ledger.jsonl")"
check "context-range sends only the slice" '"$BIN" compress show "$PKR" --full | grep -q "@2:3 of 4"'
check "context-range excludes other lines" '! "$BIN" compress show "$PKR" --full | grep -q "1	alpha"'
# H9 fix: whole files unnumbered (no per-line prefix inflating vendor input);
# ranges keep line numbers so the model knows which lines it sees.
check "whole-file pack is unnumbered"      '"$BIN" compress show "$PKF" --full | grep -qx "alpha"'
check "whole-file pack has no line prefix" '! "$BIN" compress show "$PKF" --full | grep -q "1	alpha"'
check "range pack keeps line numbers"      '"$BIN" compress show "$PKR" --full | grep -q "2	beta"'



echo "== dedup: duplicate-result elision =="
# Same successful command twice in the same scope (cwd fallback): the second
# emission is a one-line reference; recovery via the NEW artifact stays exact.
( cd "$HERE/../.." && "$BIN" shell -- git log -5 ) >"$WORK/d1.out" 2>/dev/null
( cd "$HERE/../.." && "$BIN" shell -- git log -5 ) >"$WORK/d2.out" 2>/dev/null
check "second identical shell result is a reference" 'grep -q "output identical to" "$WORK/d2.out"'
DNEW="$(grep -oE "id=bc_[A-Z0-9]+" "$WORK/d2.out" | head -1 | sed s/id=//)"
if [ -n "$DNEW" ]; then
  "$BIN" compress show "$DNEW" --full >"$WORK/drec.out" 2>/dev/null
  ( cd "$HERE/../.." && git log -5 ) >"$WORK/dorig.out" 2>/dev/null
  check "reference recovers exact bytes via NEW artifact" 'diff -q "$WORK/drec.out" "$WORK/dorig.out" >/dev/null'
fi
# Failing commands are never elided (errors are never compressed).
( cd "$HERE/../.." && "$BIN" shell -- git log --bogusflag ) >"$WORK/de1.out" 2>/dev/null || true
( cd "$HERE/../.." && "$BIN" shell -- git log --bogusflag ) >"$WORK/de2.out" 2>/dev/null || true
check "failed results never elide" '! grep -q "output identical to" "$WORK/de2.out"'
# Lossy read views elide on repeat; lossless whole-file views never do.
"$BIN" compress read "$BIGF" --outline >"$WORK/do1.out" 2>/dev/null
"$BIN" compress read "$BIGF" --outline >"$WORK/do2.out" 2>/dev/null
check "repeated lossy read view is a reference" 'grep -q "view identical to" "$WORK/do2.out"'
check "reference keeps a recovery handle" 'grep -q "recover: brain compress show" "$WORK/do2.out"'
"$BIN" compress read "$BIGF" --lines 5:9 >"$WORK/dl1.out" 2>/dev/null
check "different view kind is not cross-elided" '! grep -q "view identical to" "$WORK/dl1.out"'
printf 'tiny\n' > "$WORK/tiny.txt"
"$BIN" compress read "$WORK/tiny.txt" >/dev/null 2>&1
"$BIN" compress read "$WORK/tiny.txt" >"$WORK/dt2.out" 2>/dev/null
check "lossless whole-file view never elides" '! grep -q "identical to" "$WORK/dt2.out"'
# Config kill: dedup.enabled = false stops elision.
printf '\n[dedup]\nenabled = false\n' >> "$BRAIN_STATE_DIR/compress/compress.toml"
( cd "$HERE/../.." && "$BIN" shell -- git log -5 ) >"$WORK/dd.out" 2>/dev/null
check "dedup.enabled=false disables elision" '! grep -q "output identical to" "$WORK/dd.out"'


echo "== json projection =="
python3 -c 'import json; print(json.dumps([{"service":"svc-%03d"%i,"port":8000+i,"healthy":i%2==0,"region":"us-east"} for i in range(40)], indent=2))' > "$WORK/big.json"
"$BIN" json "$WORK/big.json" --table > "$WORK/j1.out" 2>/dev/null
check "json --table renders markdown + header"  'grep -q "mode=table" "$WORK/j1.out" && grep -q "| service | port |" "$WORK/j1.out"'
check "json header carries recovery"            'grep -q "recover: brain compress show" "$WORK/j1.out"'
check "json table is smaller than raw"          '[ "$(wc -c < "$WORK/j1.out")" -lt "$(wc -c < "$WORK/big.json")" ]'
JID="$(grep -oE "id=bc_[A-Z0-9]+" "$WORK/j1.out" | head -1 | sed s/id=//)"
"$BIN" compress show "$JID" --full > "$WORK/jrec.out" 2>/dev/null
check "json raw recovers exact bytes"           'diff -q "$WORK/jrec.out" "$WORK/big.json" >/dev/null'
"$BIN" json "$WORK/big.json" --fields service,port > "$WORK/j2.out" 2>/dev/null
check "json --fields marks omissions"           'grep -q "other fields omitted: 80 occurrences" "$WORK/j2.out"'
check "json --fields keeps allowlisted values"  'grep -q "svc-007" "$WORK/j2.out" && ! grep -q "us-east" "$WORK/j2.out"'
printf 'not json\n' | "$BIN" json - > "$WORK/j3.out" 2>"$WORK/j3.err"
check "malformed json passes through unchanged" 'grep -q "not json" "$WORK/j3.out" && grep -q "passing through" "$WORK/j3.err"'
printf '{"a":1}\n' | "$BIN" json - > "$WORK/j4.out" 2>"$WORK/j4.err"
check "no-gain input passes through honestly"   'grep -q "no byte gain" "$WORK/j4.err" && [ "$(cat "$WORK/j4.out")" = "{\"a\":1}" ]'

echo "== statusline savings segment =="
SL="$HERE/../../droplet/claude/statusline.sh"
SLIN='{"model":{"display_name":"T"},"cwd":"/tmp/x"}'
mkdir -p "$BRAIN_STATE_DIR/compress"
printf 'saved_bytes=210000 estimated_tokens=52500 divisor=4 compressed_samples=41 guarded_calls=3 updated_at=%s\n' "$(date +%s)" > "$BRAIN_STATE_DIR/compress/summary.txt"
SLOUT="$(printf '%s' "$SLIN" | bash "$SL")"
check "statusline shows labelled estimate"  'printf "%s" "$SLOUT" | grep -q "52k tok est"'
printf 'saved_bytes=100 estimated_tokens=25 divisor=4 compressed_samples=3 guarded_calls=0 updated_at=%s\n' "$(date +%s)" > "$BRAIN_STATE_DIR/compress/summary.txt"
SLOUT="$(printf '%s' "$SLIN" | bash "$SL")"
check "statusline suppresses under min samples" '! printf "%s" "$SLOUT" | grep -q "tok est"'
printf 'saved_bytes=210000 estimated_tokens=52500 divisor=4 compressed_samples=41 guarded_calls=3 updated_at=1000\n' > "$BRAIN_STATE_DIR/compress/summary.txt"
SLOUT="$(printf '%s' "$SLIN" | bash "$SL")"
check "statusline suppresses stale summary" '! printf "%s" "$SLOUT" | grep -q "tok est"'
rm -f "$BRAIN_STATE_DIR/compress/summary.txt"

echo "== p1: frozen-corpus A/B harness (offline, ab-model) =="
AB_RES="$WORK/ab"
AB_MODEL=ab-model AB_SLEEP=0 AB_BIN="$BIN" AB_RESULTS="$AB_RES" \
  BRAIN_STATE_DIR="$AB_RES/state" \
  bash "$HERE/ab/run-ab.sh" >"$WORK/ab.log" 2>&1 && RC=0 || RC=$?
check "A/B runner completes"                 '[ "'"$RC"'" = "0" ]'
check "30 result rows (15 fixtures x 2 arms)" '[ "$(wc -l < "$AB_RES/results.jsonl")" = "30" ]'
check "all 15 pairs usable"                  'grep -q "pairs: 15 usable, 0 rows dropped" "$AB_RES/report.txt"'
check "report shows exact offline output delta" 'grep -q -- "-66.7% median" "$AB_RES/report.txt"'
check "report stratifies by task category"   'for c in review debug architecture implementation config; do grep -q "  $c (n=" "$AB_RES/report.txt" || exit 1; done'
check "report labels small sample not claimable" 'grep -q "indicative, not a" "$AB_RES/report.txt"'
check "runner refuses Claude models"         '! AB_MODEL=claude-fable AB_BIN="$BIN" bash "$HERE/ab/run-ab.sh" >/dev/null 2>&1'
BRAIN_STATE_DIR="$AB_RES/state" "$BIN" compress savings > "$WORK/ab-sav.txt"
check "savings prints per-arm ground truth"  'grep -q "control 15 calls: mean" "$WORK/ab-sav.txt"'
check "savings suppresses delta under min samples" 'grep -q "delta suppressed (smallest arm 15<30" "$WORK/ab-sav.txt"'
BRAIN_STATE_DIR="$AB_RES/state" "$BIN" compress savings --json > "$WORK/ab-sav.json"
check "rollup splits output tokens per arm"  'grep -q "\"control_output_tokens\": 900" "$WORK/ab-sav.json" && grep -q "\"guarded_output_tokens\": 300" "$WORK/ab-sav.json"'
check "rollup splits input tokens per arm"   'grep -q "\"control_input_tokens\": 1" "$WORK/ab-sav.json" && grep -q "\"guarded_input_tokens\": 1" "$WORK/ab-sav.json"'
check "ground truth not claimable at n=15"   'grep -q "\"claimable\": false" "$WORK/ab-sav.json"'

echo "== p1b: A/B variant arms =="
ABV="$WORK/abv"
printf 'control\nguarded\t--response {profile}\nguard-low\t--response {profile} --effort low\n' > "$WORK/variants.tsv"
AB_MODEL=ab-model AB_SLEEP=0 AB_BIN="$BIN" AB_RESULTS="$ABV" BRAIN_STATE_DIR="$ABV/state" \
  AB_FIXTURES='04-* 13-*' AB_VARIANTS_FILE="$WORK/variants.tsv" \
  bash "$HERE/ab/run-ab.sh" >"$WORK/abv.log" 2>&1 && RC=0 || RC=$?
check "variant runner completes"            '[ "'"$RC"'" = "0" ]'
check "6 rows (2 fixtures x 3 variants)"    '[ "$(wc -l < "$ABV/results.jsonl")" = "6" ]'
check "rows carry the variant name"         'grep -q "\"variant\": \"guard-low\"" "$ABV/results.jsonl"'
check "custom compare pairs the right arms" 'python3 "$HERE/ab/analyze.py" "$ABV/results.jsonl" --compare guarded guard-low | grep -q "guard-low vs guarded"'
check "other-variant rows are ignored"      'python3 "$HERE/ab/analyze.py" "$ABV/results.jsonl" --compare control guard-low | grep -q "(ignored): 2"'
check "custom compare writes its own json"  '[ -f "$ABV/report-guard-low-vs-guarded.json" ] || python3 "$HERE/ab/analyze.py" "$ABV/results.jsonl" --compare guarded guard-low >/dev/null && [ -f "$ABV/report-guard-low-vs-guarded.json" ]'


echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]

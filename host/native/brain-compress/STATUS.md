# brain-compress — Stage 1 (native foundation + observe-only ledger): COMPLETE

Async (tokio + reqwest) native binary. One binary, dispatched on argv[0]/subcommand:
`brain-ask …`, `brain-compress …`, `brain compress …`.

## Done & verified
- **Compiles clean** (0 warnings), release binary builds (2.5 MiB, LTO).
- **5/5 unit tests** (artifact fidelity invariant + ledger savings accounting).
- **18/18 offline contract tests** on the release binary via `tests/compress/run.sh`
  (a stdlib Python fake proxy — no Claude, no vendor creds, no network egress).
- `brain-ask` is a byte-for-byte drop-in for the Bash contract: log paths,
  `.thinking` sidecar, absolute `current` symlink, streaming flush, exit codes,
  20-log retention, token never in argv/state. Reasoning never leaks to stdout.
- Observe-only accounting: raw response / thinking / prompt / system persisted as
  content-addressed artifacts; ledger records real provider usage, stop_reason,
  latency, and the ~305/199-token fixed proxy prefix (H5) as a labelled estimate.
- **Token-savings tracking** (`brain compress savings`, `stats`): three honesty
  classes never summed — provider ground-truth / measured-bytes / estimated —
  with sample-size suppression and no dollar figures. Recoveries subtract from
  claimed savings.
- Kill switch (`DISABLED` marker / `BRAIN_COMPRESS=0`) works even if the ledger
  is unreadable, checked before any other work.
- `doctor` re-verifies Stage 0 facts at runtime (proxy reachable, usage present,
  cache absent per H4, rtk presence).
- Glue: `host/bin/{brain-ask,brain-compress}` launchers (native preferred,
  Bash fallback at `host/libexec/legacy/brain-ask`), `brain compress` dispatch,
  `install.sh` builds+installs the binary and seeds `compress.toml`.

## Async design (per "always tokio, never block")
- Network path is fully async reqwest; SSE parsed incrementally from
  `bytes_stream()`; answer/thinking logs + stdout written via tokio, flushed per
  delta. No TLS feature (proxy is loopback http).
- The artifact store + ledger use short synchronous local-disk writes, ordered
  before any (future) lossy view — intentionally inline, not offloaded. Move to
  `spawn_blocking` only if soak-testing shows fs stalls.

## Deps (justified)
tokio, reqwest (no-TLS, stream), futures-util, serde_json, sha2, libc. No SQLite
(JSONL ledger + file locks); no openssl/rustls.

## Next: Stage 2 (RTK-backed Bash compression). See docs/compression-plan.md
and docs/compression-capabilities.md (esp. H6: use `rtk pipe`/`rtk rewrite`, not
RTK's unreliable tee).

---

# Stage 2 (RTK-backed Bash compression): COMPLETE

`brain-compress shell -- <cmd>` runs a command once, persists exact raw output as a
recoverable artifact, then compacts via `rtk pipe --filter` (RTK as a filter library
only — no re-run, no reliance on its unreliable tee). A mutate-only PreToolUse Bash hook
(`brain-compress hook pre-bash`) transparently reroutes eligible commands.

## Done & verified
- **Live Claude canary**: model ran `git log -20`, hook rewrote it, model received the
  185-byte compact view + recovery header instead of 10,881 bytes. Full path works.
- Compression measured: git log 10,881→321 (97%), grep-across-dir 16,573→4,783 (71%),
  git diff ~52%. **Exact byte-for-byte recovery** verified via `brain compress show --full`.
- Exit codes preserved; stderr passed through verbatim (errors never compressed); honest
  passthrough when RTK yields no gain (e.g. already-compact `--oneline`).
- Shell surface flows into the ledger → `brain compress savings` shows real measured bytes
  with sample-size suppression.
- Eligibility is conservative: only simple commands (no pipes/redirects/quoting/globs) that
  map to a verified pipe filter (git-log, git-diff, cargo-test, pytest, go-test, grep, find,
  vitest, tsc). Everything else passes through untouched; complex commands with a
  compressible tool are logged for `brain compress discover`.
- **12/12 unit tests**, **37/37 offline contract tests** (`tests/compress/run.sh`).
- Glue: `host/claude/hooks/brain-compress-bash.sh` (fail-open launcher) wired into
  `install.sh` in the same Bash matcher AFTER the deny-only consult-poll-guard — only one
  hook mutates, so no composite-mutation hazard.

## Deliberately not covered in Stage 2
- Commands whose RTK win comes from re-running with different flags (git status→--porcelain,
  ls, docker ps): not replicable single-run without a double execution, and their raw output
  is already small. Skipped by design.

---

# Stages 3, 4A, 6, 7: COMPLETE — PR is feature-complete

- **Stage 3 (response path)**: `brain-ask --response review|debug|architecture|implementation|concise`
  appends a concise-output instruction (cuts real vendor output tokens, lossless) and marks
  the call the `guarded` arm, so ground-truth savings become computable.
- **Stage 4A (context packs)**: `brain-ask --context-file PATH` / `--context-range PATH@A:B`
  — native code reads files directly and folds them into the prompt, so file bytes never
  enter the bridge's own transcript (the #1 token surface). Pack persisted + accounted; RC
  bridge agents updated to use it.
- **Stage 6 (file tools)**: `brain compress read [--outline|--query|--lines]`, `grep`, `tree`,
  each persisting exact raw + recovery. PreToolUse `pre-read` guard: observe (default, logs
  oversized reads) / enforce (denies with guidance — never silent truncation) / off.
  **Verified live**: real Claude's whole-file Read denied, model offered the alternatives.
- **Stage 7 (light)**: brain-ops.md documents the compression tools so the brain uses them.

Tests: 17/17 unit + 55/55 offline contract (`tests/compress/run.sh`). Zero warnings.

## Deferred (documented, not built)
- Stage 4B tree-sitter outlines — build risk on 1.9 GB; a lexical `--outline` ships instead.
- Stage 5 threads / provider cache — H4 showed cache/continuation unverifiable on this proxy.
- Stage 8 semantic summarization — off by default; increases total tokens for one-shot use.

---

# Measurement phase (next-plan P1 + P2): COMPLETE

- **P1 — per-arm ground truth + frozen-corpus A/B.** `RollupCell` now splits
  provider input/output tokens per experiment arm (control vs guarded); the
  all-arm totals are unchanged and remain their sum. `brain compress savings`
  prints per-arm per-call means and the guarded-vs-control delta once both arms
  reach `accounting.minimum_claim_samples` (suppressed below it); `--json` gains
  the per-arm fields plus a `claimable` flag. `tests/compress/ab/` holds 15
  frozen fixtures, a randomized paired runner (control inlines context; guarded
  uses `--response` + `--context-file`; resumable via `AB_TASKS_FILE`; refuses
  Claude models), and a stdlib analyzer (paired medians, bootstrap 95% CIs,
  per-arm truncation counts).
- **Measured (grok-4.5, 30 calls/arm, 0 failures/truncations):** output
  −545 tok/call median (−20.0%), input +154 (+39.4%) — only `debug`'s CI
  excludes zero (−26%); `review`/`implementation` profiles don't cut grok
  output and need re-tuning (P3). Full table + caveats:
  docs/compression-capabilities.md **H9**; raw evidence:
  tests/compress/ab/results-archive/grok45-2026-08-19/.
- **P2 — server-side compaction probe:** Claude Code 2.1.235 does NOT expose it
  (SDK layer supports `compact-2026-01-12`; harness never sends
  `context_management.edits`, so the injectable beta header is inert). Nothing
  wired, per the do-not-hand-roll rule. Details + re-probe recipe:
  docs/compression-capabilities.md **H8**.
- Tests: 18/18 unit (`cargo test`), 67/67 offline contract
  (`tests/compress/run.sh`, incl. 12 new A/B-harness checks against the fake
  proxy's deterministic `ab-model`). Zero warnings.

---

# Improvements round (design doc, approved 2026-08-20): COMPLETE

All seven design items built, measured where claimable, on branch
`compression-measurement` (see docs/compression-improvements-design.md):

- **Statusline savings** — estimated-class segment from summary.txt, labelled
  `est`, suppressed below min samples / stale.
- **A/B variant arms** — AB_VARIANTS_FILE / AB_FIXTURES / `analyze.py
  --compare A B`; drove the two experiment runs below.
- **Measured (H12, luna cross-vendor, 30 pairs):** guards work on every
  category — overall output −33.9% median (CI excludes zero), review −51.8%.
- **Measured (H13, grok effort lever, review+impl):** `--effort low` cuts
  output −83% vs guarded (CI excludes zero) at equal finding coverage
  (spot-checked); promoted into agents-rc/brain-grok.md + routing-rc.md.
  guard-med is not a lever. H10 is closed by H12 (model routing) + H13.
- **Dedup elision** (dedup.rs) — sha256-scoped references for byte-identical
  successful results; session-scoped via hook-captured session_id (H11),
  cwd+window fallback; recovery via the NEW artifact; lossy read views only.
- **JSON projection** (structured.rs) — `brain compress json` minify/table,
  arbitrary-precision + preserve-order fidelity, honest passthrough.
- **Explore v1** (explore.rs) — `brain explore`: bounded local gather → one
  luna consult (embedded cited-navigator prompt); discovery-only; cost
  recorded, no savings claimed. Live-verified on this repo.
- **Symbols** (brain-symbols crate + symbols.rs) — `brain compress refs` /
  `read --symbols`, tree-sitter (rust/python/ts/go/bash), marked lexical
  fallback; prebuilt via .github/workflows/release.yml (musl + SHA256SUMS —
  validated with actionlint, UNEXERCISED until pushed, per H7).
- **Recall v1** (recall.rs) — OPT-IN, DEFAULT OFF (setup offers it, Enter
  leaves it off); tf-idf × recency × role ranking; UNTRUSTED wrapper +
  redact-on-print; no savings claim, cost-only ledger rows.

Tests: 32 unit (brain-compress) + 116 offline contract checks
(tests/compress/run.sh, incl. brain-symbols build + structural checks). Zero
warnings. Evidence archives: tests/compress/ab/results-archive/{luna-2026-08-20,
grok45-effort-2026-08-20}.

# Compression engine — next phase plan (for fable)

The compression engine shipped in v0.2.1 (PR #2). This plan covers the next phase:
**prove the savings honestly, then adopt the cheap orthogonal wins.** Read these first:
`docs/compression-plan.md`, `docs/compression-capabilities.md`,
`host/native/brain-compress/STATUS.md`.

Ground rules (do not violate — they are the whole point of the subsystem):
- Never report a saving for a surface that was not actually compressed.
- Keep the three accounting classes separate (provider ground-truth / measured bytes /
  estimated); never merge them into one number; never print dollars.
- Every lossy view keeps a recovery handle. Errors, diffs, and edit sources are never compressed.
- Trust measured numbers, not advertised ones (Ponytail's advertised figures ran ~2x high).
- Test everything offline: `tests/compress/run.sh` + `tests/compress/fake_proxy.py` (no Claude,
  no network). Add checks there for anything you build. Keep `cargo test` green, zero warnings.
- Work on a branch; do not push to main or open a PR without the user's go-ahead.

## P1 — Prove it: frozen-corpus A/B (plan §5.3)
The engine is live and writing a ledger, but there is no end-to-end savings proof yet.
- Build 15–30 representative consultation fixtures (large code review, small bug, test-failure
  logs, multi-file architecture question, follow-up after a small diff, config/YAML question).
- Add a runner that sends each fixture twice — `control` (no profile/context) and `guarded`
  (`--response` + `--context-file`) — against a REAL cheap model (grok-4.5 or gpt-5.6-luna;
  never Claude, it is rate-limited), records provider ground-truth usage from the ledger, and
  reports median input/output token deltas with bootstrap confidence intervals.
- Enhance the ledger/stats so `brain compress savings` can show per-arm output-token deltas
  once ≥30 calls/arm exist (today RollupCell tracks guarded/control call COUNTS but sums
  output tokens across arms — split them per arm so the ground-truth comparison is real).
- Deliverable: a `brain compress savings` that prints an honest, defensible ground-truth
  number, plus a short written result of measured savings by task category.

## P2 — Anthropic context-compaction probe (plan Appendix D) — highest cheap win
- Determine whether Claude Code 2.1.235 lets the brain's own session enable server-side
  history compaction (the `compact-2026-01-12`-style beta header). Check the claude-api skill
  and Claude Code config/env. This targets conversation history (token-map surface #8), which
  the plan deliberately declined to touch by hand — potentially the biggest main-session win
  for near-zero build cost.
- If exposed: wire it behind `brain compress` config and document it. If not: record the
  finding in `docs/compression-capabilities.md` and move on. Do NOT hand-roll history
  compaction.

## P3 — Behavioral skill (plan Appendix A: Ponytail/Caveman)
- Add a lightweight "write the least code that solves it" skill/prompt for the main brain and
  a bridge `--response` hint, mined from Ponytail/Caveman. This cuts GENERATED tokens, which
  post-filtering cannot. Keep it a skill, not a dependency. Measure with the P1 harness before
  claiming anything.

## P4 — Headroom head-to-head (plan Appendix B)
- Only if P1 shows shell/file compression is a dominant surface. Evaluate Headroom vs RTK on
  the real command mix through the frozen corpus; adopt only what beats its own overhead.
  Do not add it as a dependency speculatively.

## Deferred unless measurement justifies (plan Stages 4B/5/8)
- 4B tree-sitter outlines — build risk on the 1.9 GB droplet; a lexical `--outline` already
  ships. Only revisit if P1 shows outlines materially beat exact-range extraction.
- 5 provider cache/threads — H4 showed cache/continuation unverifiable on this proxy. Recheck
  per-vendor (grok appeared to expose cache fields in a live doctor run — worth confirming).
- 8 semantic summarization — off by default; net-negative for one-shot use.

## Start with P1 and P2. They are the honest capstone (prove it) and the biggest cheap win.

# Frozen-corpus A/B harness (compression plan §5.3)

15 fixed consultation fixtures across the plan's task shapes (large review,
small bug, test-failure logs, architecture question, follow-up after a diff,
config questions). `run-ab.sh` sends each fixture to ONE model twice — control
(context inlined, no profile) and guarded (`--response` + `--context-file`) —
in randomized order, correlates every call with its ledger entry, and
`analyze.py` reports paired MEDIAN provider-token deltas with bootstrap 95%
CIs, overall and per category.

    AB_MODEL=grok-4.5 tests/compress/ab/run-ab.sh          # real run
    AB_MODEL=ab-model AB_SLEEP=0 BRAIN_PROXY_URL=... ...   # offline (fake proxy)

All output is the provider ground-truth accounting class only. Results land in
`results/<stamp>/` (git-ignored) with their own BRAIN_STATE_DIR, so experiment
calls never pollute the live ledger; run
`BRAIN_STATE_DIR=results/<stamp>/state brain compress savings` to see the same
arms through the normal CLI. Never point AB_MODEL at a Claude model (the runner
refuses).

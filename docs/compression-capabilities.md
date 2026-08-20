# Stage 0 — capability spike results

Measured on the live droplet, 2026-08-19. Claude Code **2.1.235**, `cli-proxy-api` on
`127.0.0.1:8317`. These results gate the design in [compression-plan.md](compression-plan.md);
re-run them before trusting the plan on a different Claude Code release.

Reproduce with `tests/compress/capabilities/` (canary transcripts under `/tmp/canary`).

## H1 — PreToolUse `updatedInput` works, for Bash **and** built-in `Read` ✅

A `PreToolUse` hook returning

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",
  "updatedInput":{...}}}
```

successfully rewrites the tool call the model actually executes.

| Canary | Setup | Result |
|---|---|---|
| A | Bash `echo CANARY_ORIGINAL`, hook rewrites the command | model's `tool_result` contained **only** `CANARY_REWRITTEN_BY_HOOK` |
| C/D | `Read` on a 500-line file, no offset/limit; hook injects `offset:1, limit:3` | `tool_result` was **62 chars** instead of ~14,000; the end-of-file marker never entered the model-visible transcript |

**Consequence:** the Read/Grep/Glob gap is *partially closable transparently* — no tool
replacement, no MCP schemas, no account. This is stronger than the plan assumed (§2.6).

**Limit:** hooks reshape tool *input* only, never tool *output*. So `Read` → outline is not
possible; `Read` → bounded ranges, and deny-with-guidance, are.

## H2 — PostToolUse cannot replace a tool result ❌ (as predicted)

A `PostToolUse` hook emitting `updatedOutput`, `tool_response`, **and** `decision:"block"`
did not remove the original. The full 10 KB blob reached the model and the hook output was
merely appended; the model reported seeing both. **PostToolUse is telemetry-only.**
Appending a compact copy after a full result saves nothing.

## H3 — Provider usage is available as ground truth ✅

Non-streaming responses carry top-level `usage`:

```json
{"id":"resp_0c96…","stop_reason":"end_turn","usage":{"input_tokens":305,"output_tokens":6}}
```

Streaming: `message_start` carries a provisional `message.usage`; the final `message_delta`
carries the authoritative `usage`. Event types observed: `message_start`,
`content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`,
`message_stop`.

Provider request IDs differ by vendor: ChatGPT family returns `resp_…` (OpenAI Responses API
style), Grok returns a UUID. This is real ground truth — use it instead of bytes÷4.

## H4 — No cache fields, no reasoning-token count ⚠️

`cache_control:{"type":"ephemeral"}` is **accepted without error**, but responses contain no
`cache_creation_input_tokens` / `cache_read_input_tokens` and no reasoning-token count.

**Consequence:** plan §2.10 Level 1 (prompt caching) is **unverifiable today** and Level 2
(continuation state) is unavailable through this endpoint. Model these as absent, not zero.
Do not claim cache savings.

## H5 — Fixed per-call overhead ⚠️

A 3-token prompt (`"Say OK."`) bills:

| Model | input_tokens |
|---|---|
| gpt-5.6-sol / gpt-5.6-luna | **305** |
| grok-4.5 | **199** |

There is a constant proxy/system prefix on every consultation. It is irreducible by
prompt-side compression and sets a floor on savings for small calls — a hundred small
consults cost ~30k input tokens before any content.

## H6 — RTK: Apache-2.0, filters excellent, **tee unreliable** ⚠️

Version tested: **v0.45.0**, `rtk-x86_64-unknown-linux-musl.tar.gz`,
sha256 `c4c036fbf181fc55ef329786c8c17e0d427972b053b825944d968a6aafef1ba4` (matches the
published `checksums.txt`). Installed to `~/.local/share/brain/vendor/rtk/0.45.0/rtk`,
**without** running `rtk init -g`.

Compression, measured on this repo:

| Command | raw | via rtk | reduction |
|---|---:|---:|---:|
| `git status` | 437 B | 74 B | 83% |
| `git log -20` | 10,881 B | 4,672 B | 57% |
| `git log -20` via `rtk pipe --filter git-log` | 10,881 B | 185 B | 98% |

Exit codes are preserved (`git status --bogusflag` → 129 both native and wrapped).

**Two findings that change the plan:**

1. **`rtk rewrite` exists** — "single source of truth for hooks". It exits 0 with the rewritten
   command, or 1 with no output when unsupported. It handles compound commands:

   ```
   git status            -> rtk git status
   cat foo | grep bar    -> cat foo | rtk grep bar
   git status && rm -rf / -> rtk git status && rm -rf /
   echo hi               -> (exit 1, no output)
   ```

   This **replaces the conservative simple-command parser** of plan §2.5. Note it rewrites
   *inside* compound commands, which is more aggressive than the plan's "simple argv only"
   rule — start conservative and only pass through what we choose to trust.

2. **RTK's tee did not materialize in any test** — not on success, not on failure, and not
   with `[tee] mode = "all"`. Only `history.db` appeared under `~/.local/share/rtk/`. The
   default config is `mode = "failures"`.

   The plan's Stage 2 gate — *"stop/rethink if RTK does not provide reliable raw recovery"* —
   therefore **fails as written**.

   **Route around it with `rtk pipe`:** brain-compress runs the real command itself, persists
   the raw output to its own artifact store (satisfying the non-negotiable invariant of §4.1),
   then feeds that raw text through `rtk pipe --filter <name>` for the compact view. We own
   recovery end to end; RTK contributes only its filter library. Its filters mark omissions
   explicitly (`[+161 lines omitted]`), which fits the fidelity contract.

**Nuisance:** rtk prints `[rtk] /!\ No hook installed — run 'rtk init -g'` to stderr. Claude
Code captures stderr into the tool result, so this must be suppressed (rate-limited by
`~/.local/share/rtk/.hook_warn_last`; set `[display] colors=false, emoji=false` and
`[telemetry] enabled=false` in a brain-managed RTK config).

## H7 — Build environment ⚠️

- **No Rust toolchain was installed.** Now: `cargo 1.97.1` / `rustc 1.97.1` via rustup.
- Droplet is 1 vCPU / **1.9 GiB RAM**, and the pre-existing 2 GiB swap was already ~70% full.
  A second 4 GiB swapfile was added (`/swapfile2`). Heavy dependency trees — and especially
  the tree-sitter grammars of Stage 4B — are a real risk here.
  Prefer shipping **prebuilt binaries** from CI over building on the droplet.
- Two checkouts exist: `~/claude-brain` is the **installed** tree that
  `~/.claude/settings.json` hook paths point at; `~/repos/claude-brain` is the dev tree.
  Any install/test procedure must be explicit about which one it touches.
- The Claude subscription is in a five-hour rate-limit window with overage rejected, so tests
  must not require calling Claude. Consultations bill the ChatGPT/Grok subscriptions instead.

## Net effect on the plan

| Plan section | Change |
|---|---|
| §2.5 shell parser | **Drop it.** Use `rtk rewrite` as the parser. |
| §2.5 tee integration | **Drop it.** Use `rtk pipe` + our own raw persistence. |
| §2.6 Read/Grep/Glob gap | **Upgrade.** Transparent input clamping is possible via PreToolUse (H1). |
| §2.10 Level 1/2 cache | **Defer.** Unverifiable on this proxy (H4). |
| §5 measurement | **Confirmed viable.** Real `usage` is available (H3); record the fixed prefix (H5). |
| Stage 4B tree-sitter | **At risk** on this hardware (H7). |

## H8 — Server-side context compaction: NOT exposed by Claude Code 2.1.235 ❌

Probed 2026-08-20 (plan Appendix D / next-phase P2) by string-analysis of the installed
Claude Code bundle (`~/.local/share/claude/versions/2.1.235`) plus the bundled claude-api
skill docs. The API feature itself is real: beta `compact-2026-01-12`, request param
`context_management: {edits: [{type: "compact_20260112"}]}` on `/v1/messages`
(Opus/Sonnet 4.6+ and Fable/Opus/Sonnet 5), and the client must echo the returned
`compaction` blocks back on subsequent turns.

What 2.1.235 actually contains:

| Layer | Server-side compaction support |
|---|---|
| Bundled TS SDK | **Full** — streams `compaction`/`compaction_delta` blocks; `toolRunner`'s old client-side `compactionControl` is deprecated in favor of `edits: [{type: "compact_20260112"}]` |
| Harness request path | **None** — no code site constructs `context_management` in a main-loop request; no `applied_edits` handling anywhere |
| Escape hatches | `ANTHROPIC_BETAS` (comma-separated list appended to the CLI's own `anthropic-beta` header) and `ANTHROPIC_CUSTOM_HEADERS` both exist and are live |

**Consequence:** the escape hatches can inject the `compact-2026-01-12` header into the
brain session's own requests, but the header alone is inert — compaction activates only
via the `context_management.edits` request param, which the harness never sends. Claude
Code's history management in 2.1.235 remains entirely client-side (`/compact`,
auto-compact via the `autoCompactWindow` setting / `CLAUDE_CODE_AUTO_COMPACT_WINDOW`,
microcompact, PreCompact hooks), which is already on by default.

**Decision:** nothing to wire (per the P2 rule: never hand-roll history compaction).
Setting `ANTHROPIC_BETAS=compact-2026-01-12` is recorded here as tried-and-understood but
NOT configured — it cannot help and any behavioral verification would burn rate-limited
Claude quota. Re-probe on each Claude Code upgrade: the moment the harness starts sending
`context_management` edits (grep the bundle for `context_management:{` and
`applied_edits`), token-map surface #8 becomes a config flip instead of a build.

## H9 — Measured A/B savings, frozen corpus vs grok-4.5 (2026-08-19/20) ✅

First end-to-end ground-truth measurement of the Stage 3/4A guards
(`--response` profile + `--context-file` pack) via `tests/compress/ab/`:
15 frozen fixtures x 2 reps x 2 arms = 60 grok-4.5 calls (30/arm — the plan's
minimum claim threshold), randomized order, paired per fixture+rep. All 60
succeeded; **0 truncated (max_tokens), 0 dropped pairs**. Raw evidence:
`tests/compress/ab/results-archive/grok45-2026-08-19/`.

Paired medians (guarded − control), bootstrap 95% CI on the absolute median:

| Category (pairs) | output tokens/call | input tokens/call |
|---|---|---|
| **overall (30)** | **−545 (−20.0%), CI [−1209, +2]** | **+154 (+39.4%), CI [+25, +172]** |
| debug (8) | −578 (−26.0%), CI [−4610, −487] | +94 (+22.0%) |
| architecture (4) | −1877 (−54.9%), CI [−2645, +246] | +131 (+35.3%) |
| config (6) | −382 (−18.3%), CI [−1826, +2] | +167 (+54.2%) |
| implementation (6) | −182 abs (+4.6% median pct), CI [−2183, +1321] | +85 (+22.9%) |
| review (6) | **+175 (+6.7%)**, CI [−1134, +7058] | +219 (+39.5%) |

The same arms through the normal CLI (arm means from the per-arm rollup split):
`brain compress savings` on the run's state dir reports control 30 calls,
mean 429 in / 4,048 out vs guarded 30 calls, mean 511 in / 3,346 out —
output −17.4%, input +19.1% per call.

**What this honestly supports:**
- **debug is the only category whose CI excludes zero** — the `debug` profile
  reliably cuts generated tokens (−26% median) on grok-4.5. Architecture and
  config point the same way but are underpowered (n=4/6).
- **The `review` and `implementation` profiles do NOT cut grok-4.5 output**
  (review trends positive: "report only findings, file:line each" appears to
  make grok enumerate at length). Re-tune those profile instructions (P3
  material) before claiming anything for them.
- **Guarded costs real vendor input**: +154 tokens/call median — the context
  pack's line-number prefixes, framing, and the profile instruction. The pack's
  purpose is keeping file bytes out of the bridge's Claude transcript (the #1
  surface), not saving vendor input; that transcript saving is accounted
  separately as measured bytes. Per the accounting rules these numbers are
  never netted against each other.
- Single vendor (grok-4.5), small per-category n, output counts include grok's
  reasoning tokens (high variance — the wide CIs are real). Re-run the same
  frozen corpus against gpt-5.6-luna before generalizing across vendors.

## H10 — Follow-up A/B after the two H9 fixes (grok-4.5, 30 pairs, 2026-08-20)

Re-ran the full frozen corpus after (a) sending whole `--context-file` bodies unnumbered and
(b) re-tuning the `review`/`implementation` profiles. Results:

- **Context-pack input fix WORKED (kept).** Overall guarded input dropped **+39.4% → +25.4%**;
  `config` input flipped from **+54% to −24%** (guarded now sends *less* than control). The
  unnumbering removed the per-line prefix overhead exactly as predicted.
- **Profile re-tune FAILED (reverted).** `review` stayed noise (+3.2%). `implementation`
  *regressed* to +50% median — driven by one fixture (`10-impl-followup-diff`) where
  "output ONLY a unified diff" made grok emit a 3× larger diff (control ~2,600 out vs guarded
  ~7,800). Confirms these categories are **output-bound by the model's reasoning/verbosity, not
  by instruction wording**; the wording was reverted to the stable baseline.
- **Unchanged, solid wins (output):** architecture −38.8% (CI [−1898, −784]), config −31.2%
  (CI excludes zero), debug −19.6% (CI excludes zero). Overall output −17.3%.

Takeaway: response profiles help debug/config/architecture output and the context-pack fix
removed the input regression; review/implementation need a *different* lever (separate profiles
proven against `concise`, or a cheaper model / lower effort), not re-wording — see
docs/compression-techniques.md.

## H11 — Hook payloads carry `session_id`, `transcript_path`, and `cwd` ✅

Probed 2026-08-20 in the Claude Code 2.1.235 bundle: the hook payload builder
constructs `{session_id: e.id, transcript_path: Gz(e.id), cwd: t, prompt_id,
permission_mode, agent_id, …}` as the base for every hook event before the
event-specific fields (`hook_event_name`, `tool_name`, `tool_input`, …) are
merged in. Session-scoped features (duplicate-result elision) can therefore
key on `session_id` from the PreToolUse hooks; the elision keeps a same-cwd +
time-window fallback for invocations that arrive without a hook (manual runs,
bridges). Session transcripts live at
`~/.claude/projects/<flattened-cwd>/<session-uuid>.jsonl` (JSONL; lines carry
`sessionId`/`timestamp`/`type`/`content`) — the substrate for `recall`; the
format is undocumented and must be parsed defensively.

## H12 — Cross-vendor A/B: the guards work EVERYWHERE on gpt-5.6-luna ✅

Full frozen corpus vs gpt-5.6-luna, 2026-08-20 (30 pairs, 2 reps, 0 failures,
0 truncations; raw evidence tests/compress/ab/results-archive/luna-2026-08-20/).
Paired medians, guarded − control:

| Category (pairs) | output tokens/call | input tokens/call |
|---|---|---|
| **overall (30)** | **−346 (−33.9%), CI [−841, −192]** | +100 (+17.1%) |
| review (6) | **−1546 (−51.8%), CI [−2231, −488]** | +105 (+14.5%) |
| architecture (4) | −934 (−70.7%), CI [−1252, −622] | +108 (+17.8%) |
| config (6) | −195 (−33.9%), CI [−748, −136] | +101 (+19.7%) |
| debug (8) | −200 (−22.0%), CI [−316, −183] | +98 (+16.0%) |
| implementation (6) | −269 (−29.9%), CI wide | +100 (+18.6%) |

Overall CI excludes zero, and — decisive for H10 — **the `review` profile that
does nothing on grok-4.5 cuts luna output by half**. H10's diagnosis is
confirmed: review/implementation were output-bound by grok's reasoning
behavior specifically, not by the profile wording. The right lever is model
routing (send review consults to a GPT-family model) and/or grok effort
(measured separately), not more wording changes. Guarded input overhead is a
steady ~+100 tokens/call (context-pack framing + profile instruction) on this
corpus's small fixtures.

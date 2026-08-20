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

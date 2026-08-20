# claude-brain compression engine — design plan

> Scoped with `gpt-5.6-sol` (effort xhigh) on 2026-08-19, seeded with a summary of
> [RTK](https://github.com/rtk-ai/rtk) and [WOZCODE](https://github.com/WithWoz/wozcode-plugin).
> Status: **proposal, nothing implemented**.


## Decisions up front

1. **Build compression as modules/applets inside `brain-native`.**
   - Applet: `brain-compress`
   - CLI surface: `brain compress ...`
   - `brain-ask` should move into the native binary early because it owns both consultation directions.

2. **Depend on RTK for command-specific shell filters. Do not reimplement its filter library.**
   - Pin and checksum an RTK release.
   - Do not run `rtk init -g`; claude-brain owns its hook configuration.
   - Build only a conservative adapter, artifact integration, metrics, and fallback behavior.

3. **Do not claim transparent Read/Grep/Glob compression unless an installed-version capability test proves PostToolUse can replace—not merely append to—the tool result.**
   - Expected fallback: optimized CLI tools plus optional PreToolUse denial for oversized built-in reads.
   - Full transparent coverage would require a Woz-style tool replacement. Do not build that in v1.

4. **Default mode is `guarded`, not aggressive.**
   - Every lossy result has an artifact handle.
   - Exact source is persisted before the compact view is emitted.
   - Semantic summarization is disabled by default.

5. **Do not pretend local reference handles create remote memory.**
   - A stateless model cannot resolve a handle from a previous call.
   - True cross-call token savings require provider continuation state or prompt caching.
   - Otherwise each request remains self-contained, using outlines, exact ranges, and diffs rather than bare references.

---

# 1. Token map and priorities

Ratios below are potential reduction of that specific surface, not a claim about total billing.

| Rank | Surface | Where tokens are spent | Potential | Cost | Decision |
|---:|---|---|---:|---:|---|
| 1 | Repeated consultation context | Bridge re-reads files, inlines them, and sends them again on every stateless follow-up | 40–90% | Medium | P0: native context packs and thread snapshots |
| 2 | Bridge’s own transcript | Claude bridge consumes full `Read` results before sending the same bytes to the remote model | 30–80% | Low–medium | P0: `brain-ask --context-file`; native code reads files directly |
| 3 | Bash/tool output | Tests, diffs, status, logs, Docker, `gh`, compiler output enter the main or bridge context | 50–95% | Low with RTK | P0: pinned RTK adapter |
| 4 | Consultation response entering Claude | Full remote prose, quoted context, code, logs, and sometimes reasoning enter the bridge transcript | 20–80% | Medium | P0: source-format contract plus deterministic post-filter |
| 5 | Consult `.log` and `.thinking` re-reads | Raw streamed output or reasoning is read back into the model unnecessarily | Up to 100% of accidental reads | Low | P0: separate raw/progress/view files; never auto-read thinking |
| 6 | Main-session built-in Read/Grep/Glob | Large files and repeated reads become tool-result payloads | 30–80% | High | P1: optimized CLI; no false transparency claim |
| 7 | Re-reads after edits | Whole files are read when only changed/current ranges are needed | 60–95% | Medium | P1: exact ranges and `git diff`-aware reads |
| 8 | Main conversation history | Prior assistant messages and tool results are resent until Claude Code compacts the session | High | Very high/risky | Use Claude Code’s built-in compaction; do not replace it |
| 9 | Injected `CLAUDE.md` material | `routing-rc.md`, `brain-ops.md`, and consult policy are repeatedly present | 20–60% of injected docs | Low | P1: concise index plus on-demand detail |
| 10 | Subagent metadata/transcripts | Agent prompts, tool schemas, bridge boilerplate, and verbose final returns | 10–40% | Low–medium | Minify prompts; bridge returns compact response without restating |
| 11 | MCP schemas | Tool definitions can be a large fixed prefix | Potentially material | High/outside control | Report and prune unused MCP servers; do not rewrite schemas |
| 12 | Main Claude output | Becomes future context, but is also the user-visible answer | 10–30% via style | High fidelity risk | Only instruct “do not restate artifacts”; no post-processing |
| 13 | Statusline and silent hooks | Normally UI/local only, not model context | Negligible | Low | Keep hook success output empty; otherwise ignore |

## Important distinctions

- Filtering a remote response **after generation** saves tokens entering Claude, but does **not** reduce the vendor’s generated output tokens.
- A concise response contract sent to the remote model can reduce actual vendor output usage.
- Hiding `.thinking` from Claude prevents downstream input growth but does not reduce reasoning generation. Do not automatically lower `--effort`.
- Static system text may benefit from provider prompt caching, so its billing impact may be smaller than its context-size impact.

---

# 2. Architecture

## 2.1 Components

Put these in the planned `brain-native` crate. If that crate has not landed, create it under `host/native/brain-native/` and preserve the same module boundaries when the migration merges.

```text
host/native/brain-native/
  src/
    applets/
      ask.rs
      compress.rs
    compress/
      artifact.rs       # exact raw storage, manifests, recovery
      config.rs
      hook.rs           # Claude Code hook JSON handling
      shell.rs          # RTK adapter
      pack.rs           # consultation context packs
      outline.rs        # code outlines and exact-range extraction
      response.rs       # response contracts and deterministic filters
      thread.rs         # follow-up snapshots/capabilities
      ledger.rs         # metrics/event recording
      stats.rs
      sensitive.rs
```

Repository additions and modifications:

```text
host/bin/brain-compress                    # rollback-capable launcher
host/bin/brain                            # "compress" dispatch
host/bin/brain-ask                        # launcher to native applet, Bash fallback retained
host/lib/common.sh                        # state/config paths
host/install.sh                           # binary, RTK, config, hooks, symlinks
host/templates/compress.toml.tmpl
host/claude/hooks/brain-pre-bash.sh       # stable launcher for composite Bash hook
host/claude/hooks/brain-pre-file.sh       # optional oversized Read guard
host/claude/hooks/brain-post-tool.sh      # silent telemetry only
host/claude/agents-rc/brain-*.md           # use --context-file, never inline whole files
host/claude/agents-multi/*.md             # same where applicable
host/claude/routing-rc.md
host/claude/brain-ops.md
host/claude/consult-background.md
host/claude/consult-foreground.md
host/claude/statusline.sh
tests/compress/
```

Do not expose compression through MCP. That would add schemas to every main-model request. Use CLI/applets through Bash.

## 2.2 CLI

```bash
brain compress status
brain compress on [--mode guarded|lossless|aggressive]
brain compress off [--global|--session SESSION]
brain compress stats [--since 24h] [--surface consult|shell|files] [--json]
brain compress show ARTIFACT [--view|--full] [--lines START:END]
brain compress grep ARTIFACT PATTERN
brain compress gc
brain compress doctor
brain compress discover

brain compress read PATH [--outline] [--query TEXT] [--lines A:B]
brain compress grep PATTERN [PATH ...] [--context N] [--max-matches N]
brain compress tree [PATH] [--depth N]

brain compress pack create \
  --query-file QUERY \
  --context-file PATH \
  --context-range PATH@START:END \
  --context-diff PATH@BASE \
  --budget 12000 \
  --mode guarded \
  --out PACK
```

Extend `brain-ask` without breaking the current interface:

```bash
brain-ask sol \
  --context-file src/lib.rs \
  --context-file src/main.rs \
  --context-range tests/x.rs@40:180 \
  --thread ct_ABC123 \
  --compress guarded \
  --response compact \
  -
```

Existing opaque stdin remains supported:

```bash
brain-ask sol --compress off -
```

For opaque prompts, `auto` may normalize exact duplicate blocks and response handling, but must not infer and skeletonize arbitrary fenced text. The bridge agents must use the structured context options to get prompt-side compression.

## 2.3 State layout

Use SQLite in WAL mode for concurrent hooks/applets, plus content-addressed blobs:

```text
$BRAIN_STATE_DIR/compress/
  DISABLED
  state.db
  artifacts/
    ab/cd/<sha256>.zst
  tmp/
  consult/
    <call-id>/
      events.ndjson
      response.raw
      response.view
      thinking.raw
      progress
      usage.json
```

Core tables:

```sql
artifacts(
  id TEXT PRIMARY KEY,
  sha256 TEXT,
  kind TEXT,
  raw_path TEXT,
  raw_bytes INTEGER,
  view_bytes INTEGER,
  transform_json TEXT,
  reversible INTEGER,
  sensitivity TEXT,
  created_at INTEGER,
  pin_until INTEGER
);

calls(
  id TEXT PRIMARY KEY,
  surface TEXT,
  session_id TEXT,
  thread_id TEXT,
  arm TEXT,
  model TEXT,
  mode TEXT,
  provider_request_id TEXT,
  source_bytes INTEGER,
  sent_bytes INTEGER,
  response_raw_bytes INTEGER,
  response_view_bytes INTEGER,
  provider_usage_json TEXT,
  latency_ms INTEGER,
  stop_reason TEXT,
  outcome TEXT,
  created_at INTEGER
);

thread_files(
  thread_id TEXT,
  path TEXT,
  base_sha256 TEXT,
  current_sha256 TEXT,
  artifact_id TEXT,
  last_representation TEXT,
  PRIMARY KEY(thread_id, path)
);

recoveries(
  call_id TEXT,
  artifact_id TEXT,
  requester TEXT,
  requested_ranges TEXT,
  created_at INTEGER
);
```

All directories are `0700`; files and the database are `0600`.

## 2.4 Main Bash data flow

```text
Claude Bash tool
  -> PreToolUse "Bash"
  -> existing consult-poll guard
  -> conservative command parser
  -> eligible simple command?
       no: unchanged
       yes: rewrite to brain-compress shell --rtk ... -- argv
  -> pinned RTK executes command and creates raw tee
  -> brain-compress imports tee, captures compact output, records metrics
  -> compact output begins with recovery header
  -> Claude receives compact result
  -> Claude can run "brain compress show bc_... --lines ..."
```

### Hook composition

Do not install two independently mutating Bash PreToolUse hooks and assume their `updatedInput` results compose.

Create one composite Bash hook:

```text
host/claude/hooks/brain-pre-bash.sh
  -> brain-compress hook pre-bash
```

Its native implementation performs:

1. Existing `consult-poll-guard.sh` behavior.
2. Compression kill-switch check.
3. RTK eligibility and rewrite.

Keep `consult-poll-guard.sh` installed on disk for rollback. `install.sh` replaces its settings entry only after `brain compress doctor` passes.

## 2.5 Bash strategy: use RTK, do not clone it

### Recommendation

- Install RTK under:

```text
~/.local/share/brain/vendor/rtk/<version>/rtk
```

- Pin version and SHA-256 in the repository.
- Verify its license before Stage 2.
- Do not invoke `rtk init -g`.
- Do not vendor or fork its 100+ filters.
- Do not implement an arbitrary shell parser.

The native hook should only rewrite a **single simple command** that can safely be represented as argv:

- Optional environment assignments.
- No `|`, `&&`, `||`, `;`, redirects, substitutions, heredocs, or shell globs.
- Command must be on a tested allowlist of RTK-supported command families.

Examples initially covered:

```text
git status/diff/log
ls/tree
cargo test/check/clippy
go test
pytest
npm/pnpm/yarn test
eslint/tsc
docker ps/logs
gh pr/issue
kubectl get/logs
journalctl/systemctl
```

Complex commands remain unchanged and are reported by `brain compress discover`.

The wrapper must:

- Preserve stdout/stderr separation where possible.
- Preserve exit status.
- Import or reference RTK’s full tee before emitting a lossy view.
- Fall back to executing the original argv directly if RTK is missing or disabled.
- Reject a pinned RTK version if its output no longer exposes a recoverable tee path.

This adapter is the “thin brain-native subset”: command recognition and artifact integration only, not filtering logic.

## 2.6 Read/Grep/Glob gap

### What hooks can safely be assumed to do

Treat these capabilities as version-dependent until tested on the installed Claude Code release:

- `PreToolUse` may be able to alter tool input through an `updatedInput`-style response.
- A generic `PostToolUse` hook commonly receives the result and may append context, but **must not be assumed to remove or replace the original result**.
- Appending a compact copy after the full result does not save tokens.

Stage 0 must run a canary:

1. A tool returns a unique 10–20 KB string.
2. PostToolUse attempts to replace it with a short marker.
3. Inspect the transcript and, if available, model usage.
4. Replacement is considered supported only if the original canary text is absent from the model-visible transcript.

### Default fallback

Do not transparently rewrite built-in Read into Bash. Instead:

- Install `brain compress read`, `grep`, and `tree`.
- Tell agents to prefer them for:
  - Files over 48 KiB or 800 lines.
  - Discovery where only symbols or matching regions are needed.
  - Re-reading a file after an edit.
- Keep built-in `Read` for small files and exact edit preparation.
- Add an optional `read_guard = "enforce"` mode that denies oversized unrestricted Reads and returns:

```text
File is 2,840 lines. Use:
brain compress read path --outline
brain compress read path --query '<goal>'
or re-run Read with explicit offset/limit.
```

Default `read_guard` is `observe`, not `enforce`.

A true transparent solution requires replacement tools or a plugin analogous to Woz. Do not build that unless the CLI adoption rate is poor and measurements show built-in reads remain a dominant surface.

## 2.7 Consultation data flow

```text
Bridge receives task and paths
  -> bridge does NOT Read and inline whole files
  -> brain-ask --context-file ... receives paths
  -> native code snapshots files directly
  -> pack engine selects exact ranges/outlines/diffs under budget
  -> exact task + self-contained pack POSTed to local proxy
  -> raw SSE/JSON saved before filtering
  -> provider usage captured
  -> thinking saved but not printed
  -> response is source-constrained and deterministically compacted
  -> compact response only goes to bridge stdout
  -> bridge returns it without restating
```

This immediately saves Claude bridge tokens even when the remote model still receives a full file: the bridge no longer consumes a `Read` result and then repeats it in a Bash command.

### Streaming behavior

Current `--stream` should change as follows:

- Raw text deltas go to `response.raw`.
- Reasoning deltas go to `thinking.raw`.
- A bounded `progress` file is updated for the statusline.
- Bash stdout remains quiet until completion, then emits `response.view`.
- `current` points to `progress` during the call and to `response.view` afterward.
- Raw output is retrieved by artifact handle, not by reading `current`.

This avoids putting the streamed response and then the final response into the bridge transcript twice.

## 2.8 Safe compression by destination

| Destination | Allowed default | Not allowed by default |
|---|---|---|
| Main brain, receiving tool/consult output | Lossy views with local artifact handles; exact ranges on demand | Silent omission; inaccessible recovery references |
| Remote frontier consultant | Self-contained outlines, exact ranges, diffs, path tables; bounded context-request protocol | Bare local handles or assumptions that the model remembers earlier calls |
| User, receiving main Claude answer | Source instruction not to restate artifacts | Post-processing or suppressing requested code/details |
| Semantic summarizer | Non-sensitive logs/docs only, explicit opt-in | Secrets, patches, edit source, errors requiring exact diagnosis |

## 2.9 Context packs

Rendered packs should use a simple, explicit format:

```text
<BRAIN_CONTEXT_PACK version=1 id=cp_ABC mode=guarded>
Rules:
- All omissions are marked.
- References are valid only within this request.
- Request exact omitted ranges using the nonce-qualified protocol below.

PATHS
P1 = src/router.rs
P2 = src/config.rs

ARTIFACT F1
path=P1 sha256=... representation=outline raw_lines=842
imports: lines 1-22
struct Router: lines 41-68
fn route(req: Request) -> Result<Response>: body omitted lines 122-286
fn map_error(...): body omitted lines 301-344
END F1

ARTIFACT F2
path=P2 sha256=... representation=exact-ranges
--- lines 80-170 ---
...
END F2
</BRAIN_CONTEXT_PACK>
```

For omitted remote context, include a per-call nonce:

```text
BRAIN_CONTEXT_REQUEST <nonce> {"ref":"F1","ranges":[[122,210]],"reason":"Need routing logic"}
```

`brain-ask` validates requests and may perform up to two automatic follow-up calls. It must only serve:

- References already in the pack.
- Explicit bounded line ranges.
- A configured maximum number of bytes.
- No arbitrary paths supplied by the remote output.

If a provider is stateless, the second request includes the original compact pack plus the newly requested exact ranges.

## 2.10 Cross-call context cache

Implement three capability levels and report the active level in `brain compress doctor`.

### Level 0: local snapshots only

Always available.

- Store file hashes and exact snapshots.
- Avoid re-reading files through Claude.
- Detect changed files.
- Build a new self-contained pack for every remote call.
- Use current query relevance to omit irrelevant unchanged bodies.
- Do not emit bare “same as F1 from last call” references.

This saves bridge tokens and local work, but it is not true remote input deduplication.

### Level 1: provider prompt caching

Use only when verified through provider usage fields.

- Order request blocks as:
  1. Stable system instructions.
  2. Stable context pack.
  3. Volatile follow-up question.
- Remove timestamps and random IDs from the stable prefix.
- Use cache-control annotations only if `cli-proxy-api` demonstrably forwards them.
- Record `cache_read_input_tokens` or equivalent.

The full context may still be logically present, but cache-read billing/latency can improve.

### Level 2: provider continuation state

Use only if the local proxy exposes a real provider continuation ID or equivalent.

- Store the provider state ID in `threads`.
- Send deltas and exact changed ranges.
- Fall back to Level 0 if continuation fails.
- Never emulate provider memory by silently omitting required context.

Do not modify or fork `cli-proxy-api` merely to obtain continuation support in v1.

### Stateless follow-ups

For Level 0 providers, a follow-up request should contain:

- Exact current user question.
- A compact task capsule.
- Previous answer verbatim if short; otherwise a marked, non-authoritative handoff.
- Current file outlines.
- Exact changed hunks and surrounding ranges.
- Any exact ranges relevant to the new question.

A diff alone is insufficient when the remote model does not have the base.

---

# 3. Compression techniques

Ratios are expected reductions of the affected artifact.

| Technique | Expected ratio | Fidelity risk | Reversible? | Default use |
|---|---:|---|---|---|
| RTK command-specific filters | 50–95% | Low–medium; parser/version dependent | Raw tee: yes | Yes |
| Collapse repeated identical log lines with counts | 60–99% | Low if byte-identical only | Yes with raw; count representation is exact | Yes |
| Group passing tests, preserve failures | 70–95% | Medium | Raw tee: yes | Known test runners only |
| Exact-range extraction | 60–98% | Medium: omitted caller/context may matter | Raw snapshot: yes | Yes |
| Code outline/skeleton | 60–95% | High for behavior questions | Raw snapshot: yes | Discovery and remote request protocol |
| Diff plus exact surrounding hunks | 80–99% for small changes | High without a base | Locally yes with base snapshot | Follow-ups with outline/base context |
| Exact duplicate block deduplication | 10–80% | Low | Yes | Same prompt; cross-call only with real state/cache |
| Path shortening with path table | 5–20% | Low | Yes | Long repeated paths |
| Minified JSON | 10–40% | Low if data unchanged | Yes | Nested/sparse structures |
| Escaped TSV/row format | 25–70% vs verbose JSON | Medium if schema/escaping is weak | Yes if all fields retained | Homogeneous command records |
| Blank-line/prose normalization | 5–20% | Low | Raw recovery only | Yes |
| Comment stripping | 10–40% | High | No, except via raw snapshot | Off by default |
| Input-echo replacement in remote responses | 20–70% | Low if exact matched lines | Raw response: yes | Yes for exact matches |
| Source request for concise output | 20–50% generated output | Medium; may omit nuance | No | Profile-specific |
| Semantic model summary | 70–95% | High | No, only raw recovery | Experimental only |

## 3.1 Structured output format

Do not invent a proprietary TOON dialect in v1.

Use:

- **Escaped TSV with a declared schema** for homogeneous rows.
- **JSONL or minified JSON** for nested/sparse objects.
- **Plain compact prose** for small, heterogeneous findings.
- Avoid Markdown tables: pipe/separator overhead is high and escaping is ambiguous.

Example:

```text
COLUMNS name:string status:string age:string ports:string
web-1   running  2h   80,443
worker  exited   4m   -
```

Tabs/newlines inside cells must be JSON-escaped. Never drop fields without an explicit marker.

## 3.2 Code-aware skeletonization

Support languages in this order:

1. Rust
2. Go
3. Python
4. JavaScript/TypeScript
5. Bash

Use tree-sitter where a maintained grammar is available. Do not present regex-generated outlines as authoritative. For unsupported languages, use exact lexical matches and bounded ranges.

An outline includes:

- Module/package/import declarations.
- Type, trait, interface, class, function, and method signatures.
- Relevant attributes and decorators.
- Line ranges.
- Body omission markers with hashes.
- Selected exact bodies based on query symbols and lexical matches.

Example:

```text
fn route(req: Request) -> Result<Response>  lines=122-286 body_sha=...
  [body omitted; request F1:122-286]
```

Do not strip:

- `//go:build`
- `eslint`/`tsc` directives
- shellcheck directives
- Rust attributes or doc tests
- comments selected by the query
- comments in exact edit ranges

## 3.3 Diff-only re-sends

Safe rules:

- All added and deleted lines remain exact.
- Unchanged diff context may be reduced, but omissions are marked.
- A local base snapshot is always retained.
- For stateless remotes, include a current outline and exact surrounding definitions.
- Use bare diff-only requests only with verified provider continuation state.

Never transform the content of a patch that will be applied.

## 3.4 Semantic summarization

Default: disabled.

There is no sensible local LLM for a small $12 droplet without adding substantial latency and operational complexity. If experimentation is justified, use a configured cheap model behind the existing proxy, with `luna` as the first candidate only after measuring its cost, latency, and quality.

Use semantic summarization only when all are true:

- Source is at least approximately 12,000 tokens.
- The compact artifact is expected to be reused at least three times, or it replaces input to a much scarcer model.
- Expected summary size is at most 20% of source.
- Content is prose, documentation, or repetitive logs.
- Content contains no secrets, patches, edit source, or diagnostically important unknown errors.
- The summarizer call runs with compression disabled to prevent recursion.

Break-even condition:

```text
summarizer input/output cost
  <
number of downstream uses × target-model savings
```

For a one-time call, semantic summarization usually increases total ecosystem tokens. Prefer asking the original consultant for a concise result at generation time.

---

# 4. Fidelity and safety contract

## 4.1 Non-negotiable invariant

**No lossy view is emitted until an exact recoverable source has been successfully persisted or is already immutable and addressable.**

If persistence fails:

- Do not emit a lossy view.
- Bypass compression and emit the original result with a warning.
- In strict mode, fail closed instead.

Every lossy result begins with a header so recovery survives tail truncation:

```text
[brain-compress id=bc_7H2K raw_sha256=... raw_bytes=184220 view_bytes=12844 lossy=yes]
```

It ends with:

```text
[omitted: 3,844 lines; recover: brain compress show bc_7H2K --full]
```

Specific omission sites must also be marked inline.

## 4.2 Recovery commands

```bash
brain compress show bc_7H2K
brain compress show bc_7H2K --lines 120:240
brain compress show bc_7H2K --full
brain compress grep bc_7H2K 'panic|ERROR'
```

`show` without options prints metadata and suggested ranges, not the full artifact.

For the main brain, the model can invoke these commands directly.

For a remote model, the nonce-qualified context request causes `brain-ask` to issue a bounded follow-up.

## 4.3 Retention

Defaults:

- Active session/thread artifacts are pinned.
- On thread close, retain for seven additional days.
- Other artifacts: 14-day retention.
- Global default quota: 2 GiB.
- Compress blobs with zstd.
- GC never evicts pinned artifacts.
- If an artifact cannot be stored due to quota or disk pressure, bypass lossy compression.

Artifact metadata should state its expiry. `brain compress gc --dry-run` must be available.

## 4.4 Never compress or mutate

Never alter these inputs:

- User instructions.
- System safety, permission, or routing instructions.
- `Write`, `Edit`, `NotebookEdit`, patch, or heredoc input.
- Command arguments or stdin beyond wrapping the command invocation.
- Added/deleted lines in a displayed diff.
- Exact replacement text intended for application.
- Binary data.
- Authentication tokens, OAuth stores, SSH keys, or credential files.
- A provider response whose `stop_reason` indicates max-token truncation.

For files the model is about to edit:

- An outline is a discovery view only.
- The view must say `NOT AN EDIT SOURCE`.
- The model must obtain exact current lines before applying an edit.
- Do not attempt to enforce this through undocumented Claude behavior in v1.

## 4.5 Errors

Do not adopt a blanket “failure output is always compacted” rule.

- For known test runners:
  - Preserve all unique failure messages and relevant stack traces.
  - Collapse passing cases.
  - Collapse byte-identical repeated failures with counts.
- For known compilers:
  - Preserve all error and warning diagnostics.
  - Collapse repeated build boilerplate.
- For unknown commands returning non-zero:
  - Default to uncompressed output.
- Always preserve exact exit code.

## 4.6 Secrets

Default remote denylist:

```text
~/.ssh/**
~/.cli-proxy-api/**
**/.env
**/.env.*
**/*credentials*
**/*secret*
**/*token*
/etc/shadow
```

Behavior:

- Reject adding these paths to a consultation pack unless `--allow-sensitive` is explicit.
- Never send sensitive artifacts to a semantic summarizer.
- If explicitly allowed, use exact/range representations only and shorter retention.
- Do not promise generic secret scanning is complete.
- Do not build artifact encryption in v1; rely on droplet filesystem permissions.

## 4.7 Truncated remote output

If the provider reports token-limit truncation:

```text
[REMOTE RESPONSE INCOMPLETE: stop_reason=max_tokens, artifact=bc_...]
```

`brain-ask` may automatically request continuation once. It must never present a truncated answer as complete.

## 4.8 Kill switches

Per call:

```bash
brain-ask sol --compress off -
BRAIN_COMPRESS=0 brain-ask sol -
```

Global:

```bash
brain compress off
touch "$BRAIN_STATE_DIR/compress/DISABLED"
```

Per surface in config:

```toml
[shell]
enabled = false

[consult]
prompt_enabled = false
response_enabled = false

[file_tools]
read_guard = "off"
```

Hooks check `DISABLED` before any other work and proceed without rewriting. The disable marker must work even if the database is corrupt.

---

# 5. Measurement

## 5.1 Ground-truth versus estimates

Report three separate classes. Never combine them into one fake token number.

### A. Provider-ground-truth consultation usage

Capture from every `cli-proxy-api` response:

- Input tokens.
- Output tokens.
- Reasoning tokens, if exposed.
- Cache creation/read tokens.
- Stop reason.
- Provider request ID.
- Latency and retries.

For streaming responses, parse usage from the initial/final SSE events and retain the raw event stream.

### B. Downstream artifact reduction

For shell outputs, response views, and file views:

- Raw bytes.
- Compact bytes.
- Exact transform list.
- Estimated tokens, clearly labeled.
- Whether recovery was used.

This proves context reduction but not vendor billing reduction.

### C. Main Claude session usage

First inspect what the installed Claude Code statusline JSON exposes. If it includes cumulative/current usage, have `statusline.sh` silently record samples.

Potential fields include:

- Input/output tokens.
- Cache-read/cache-write tokens.
- Context-window usage.
- Session cost.

This is version-dependent. If unavailable, report main-session savings only as estimated artifact reductions. Do not scrape undocumented transcripts unless the capability spike finds a stable format.

## 5.2 `brain compress stats`

Example structure:

```text
Compression
  mode: guarded
  shell backend: RTK 0.x.y
  consult capability:
    sol: prompt-cache verified
    grok: stateless
    kimi: stateless
  artifact store: 418 MiB / 2 GiB
  recovery health: OK

Last 24h

CONSULT — provider-reported
  calls: 18
  input tokens sent: 184,220
  cache-read tokens: 61,040
  output tokens generated: 23,110
  reasoning tokens: 8,440
  max-token truncations: 0
  median latency: 18.2s

CONSULT — model-visible views
  source bytes considered: 4.8 MiB
  prompt bytes sent: 1.6 MiB
  raw response bytes: 920 KiB
  response bytes delivered to Claude: 271 KiB
  remote context requests: 3
  extra request rounds: 2

SHELL — estimated
  commands compacted: 43
  raw bytes: 3.1 MiB
  delivered bytes: 402 KiB
  reduction: 87.3%
  parser bypasses: 17
  RTK failures: 0

FILES — estimated
  compact reads: 21
  raw bytes: 1.7 MiB
  delivered bytes: 388 KiB
  full recoveries: 4

SAFETY
  artifacts recovered: 9
  missing artifacts: 0
  sensitive-path blocks: 2
  compression-related retries: 1
  user-rated bad results: 0
```

For models with subscriptions rather than metered pricing, do not print dollar savings unless the user configures a pricing table. Tokens, rate-limit consumption, context use, and latency are the honest metrics.

## 5.3 A/B methodology

### Assignment

- Use `hash(session_id or consult_thread_id) % 2`.
- Keep a complete session/thread in one arm.
- Arms:
  - `control`: instrumentation and raw preservation, but raw output/prompt.
  - `guarded`: planned default compression.
- Record the arm on every call.

### Real-task comparison

Stratify by:

- Model.
- Task category: review, debugging, architecture, implementation.
- Number of files and source bytes.
- Initial versus follow-up call.
- Requested response profile.

Compare:

- Provider input/output tokens per completed consultation.
- Number of consultation rounds.
- Latency.
- Context-request rate.
- Recovery rate.
- Tool reruns.
- Test/lint success.
- User overrides and negative ratings.

Use medians and bootstrap confidence intervals. Do not rely on raw averages.

### Paired frozen corpus

Maintain 15–30 representative consultation fixtures:

- Large code review.
- Small targeted bug.
- Test failure logs.
- Multi-file architecture question.
- Follow-up after a small diff.
- Config/YAML question.

Run both control and guarded modes in randomized order. Evaluate:

- Factual correctness.
- Whether every reported issue is grounded in available context.
- Test or patch success where applicable.
- Human preference.
- Actual provider usage.

Do not replay user-sensitive prompts without explicit opt-in.

### Minimum claim threshold

Do not advertise measured savings until there are at least:

- 30 real consultation calls per arm, and
- 10 repeated/follow-up threads per arm, and
- No statistically meaningful task-success regression.

---

# 6. Implementation stages

Effort assumes one competent engineer and excludes the already-planned general Bash-to-Rust migration.

## Stage 0 — Capability and dependency spike

**Effort:** 2–4 engineer-days  
**Behavior change:** None

### Work

- Verify installed Claude Code hook behavior:
  - Bash `PreToolUse` input modification.
  - Whether multiple mutating hooks compose.
  - Generic PostToolUse result replacement canary.
  - Statusline usage fields.
- Inspect raw `cli-proxy-api` JSON and SSE usage for every configured model.
- Probe cache usage fields and continuation IDs.
- Verify RTK:
  - License.
  - Release installation.
  - CLI proxy behavior.
  - Tee path contract.
  - Exit-code preservation.
  - Unsupported-command behavior.

### Files

```text
tests/compress/capabilities/
scripts/compress-capability-check.sh
docs/compression-capabilities.md
```

### Stop/rethink if

- RTK licensing is incompatible.
- RTK does not provide reliable raw recovery.
- `cli-proxy-api` strips all usage fields.
- A second mutating Bash hook cannot be safely composed—then proceed with the planned composite hook only.
- PostToolUse cannot replace results—expected; proceed with CLI fallback.

---

## Stage 1 — Native foundation and observe-only ledger

**Effort:** 5–7 days  
**Behavior change:** None by default

### Work

- Add artifact store, SQLite ledger, config, kill switch, and stats.
- Add `brain compress status/show/stats/gc/doctor`.
- Move `brain-ask` HTTP/SSE parsing into native code behind the existing launcher.
- Persist raw consult responses, thinking, stop reason, and exact provider usage.
- Preserve existing `brain-ask` output behavior in control mode.
- Tap statusline usage if supported.

### Files

```text
host/native/brain-native/src/compress/*
host/native/brain-native/src/applets/{ask,compress}.rs
host/bin/brain
host/bin/brain-ask
host/bin/brain-compress
host/lib/common.sh
host/install.sh
host/templates/compress.toml.tmpl
host/claude/statusline.sh
tests/compress/artifact/
tests/compress/fake-proxy/
```

### Acceptance criteria

- Exact raw response hash survives save/read round trip.
- Streaming and non-streaming usage are captured.
- `brain compress off` works if the database is unavailable.
- Bash fallback remains usable by moving the native `current` symlink back.

### Stop/rethink if

- Native `brain-ask` changes model behavior or streaming semantics.
- Raw event storage grows without a workable quota.
- Provider usage cannot be correlated with local call IDs.

---

## Stage 2 — RTK-backed Bash compression

**Effort:** 4–6 days  
**Behavior change:** Opt-in, then guarded default

### Work

- Pin/install RTK with checksum.
- Implement conservative simple-command parsing.
- Implement `brain-compress shell --rtk ...`.
- Integrate RTK tee artifacts into the brain artifact store.
- Port the existing consult polling guard into the composite native Bash hook.
- Add `brain compress discover`.
- Add golden fixtures for the top command families.

### Files

```text
host/install.sh
host/claude/hooks/brain-pre-bash.sh
host/native/brain-native/src/compress/{hook,shell}.rs
host/templates/compress.toml.tmpl
tests/compress/shell/
```

### Rollback

- Disable `[shell]`.
- Reinstall the old `consult-poll-guard.sh` settings entry.
- Remove the RTK vendor directory.

### Stop/rethink if

- Exit status or signal behavior changes.
- More than 1% of rewritten commands require manual rerun.
- Median wrapper overhead exceeds 50 ms.
- RTK output cannot reliably be associated with its raw tee.
- Maintaining compatibility requires forking RTK.

---

## Stage 3 — Consultation response path

**Effort:** 4–6 days  
**Behavior change:** Opt-in per bridge/model

### Work

- Add response profiles:
  - `review`
  - `debug`
  - `implementation`
  - `architecture`
- Add concise source instructions:
  - Do not restate prompt.
  - Cite file refs and lines.
  - Do not quote unchanged code.
  - Return unified diffs only when requested.
- Keep thinking out of stdout.
- Add deterministic filters:
  - Exact repeated paragraph collapse.
  - Exact input-echo replacement with references.
  - Blank-line normalization.
  - Repeated log-line grouping.
- Detect and handle token-limit truncation.
- Update current/progress symlink behavior.
- Tell bridges to return compact output without restating it.

### Files

```text
host/native/brain-native/src/compress/response.rs
host/bin/brain-ask
host/claude/agents-rc/brain-*.md
host/claude/agents-multi/*.md
host/claude/consult-background.md
host/claude/consult-foreground.md
host/claude/statusline.sh
tests/compress/responses/
```

### Stop/rethink if

- Source concision increases clarification/follow-up calls enough to eliminate savings.
- Code blocks or patches are altered.
- Raw and compact outputs cannot be cleanly separated from Claude’s Bash result.

---

## Stage 4A — Structured consultation packs without semantic parsing

**Effort:** 5–7 days  
**Behavior change:** Bridges opt in

### Work

- Add `--context-file`, `--context-range`, `--context-diff`, and `--pack`.
- Snapshot exact files directly from native code.
- Implement:
  - Path tables.
  - Exact duplicate deduplication.
  - Query-term matches with bounded context.
  - Exact git diff hunks.
  - Full inclusion for small files.
  - Explicit omission markers.
- Add nonce-qualified remote context requests and up to two automatic fulfillment rounds.
- Rewrite bridge agents so they pass paths instead of reading and inlining whole files.

### Files

```text
host/native/brain-native/src/compress/{pack,thread,sensitive}.rs
host/native/brain-native/src/applets/ask.rs
host/claude/agents-rc/brain-*.md
host/claude/agents-multi/*.md
host/claude/routing-rc.md
host/claude/brain-ops.md
tests/compress/packs/
```

### Acceptance criteria

- Bridge transcript never contains context-file bodies unless it explicitly recovers them.
- Remote request is self-contained.
- Every omitted range can be fulfilled from the exact snapshot.
- Remote output cannot request an arbitrary path.

### Stop/rethink if

- More than 20% of calls require a recovery round.
- Recovery rounds consume more tokens than full-context control.
- Bridge agents continue to use built-in Read for full files.

---

## Stage 4B — Code outlines

**Effort:** 5–8 days  
**Behavior change:** Guarded profile only

### Work

- Add tree-sitter outlines for Rust, Go, Python, JS/TS, and Bash.
- Add query-based exact body selection.
- Fall back to exact lexical ranges for unsupported or parse-failing files.
- Mark outlines `NOT AN EDIT SOURCE`.

### Files

```text
host/native/brain-native/src/compress/outline.rs
host/native/brain-native/Cargo.toml
tests/compress/outline/
```

### Stop/rethink if

- Grammar dependencies materially bloat installation/update time.
- Parse failures lead to misleading outlines.
- Quality results are not better than simple exact-range extraction.

---

## Stage 5 — Threads, cache capability, and follow-up diffs

**Effort:** 5–8 days  
**Behavior change:** Opt-in through `--thread`

### Work

- Add explicit thread handles.
- Track file snapshots and previous representations.
- Build stable prefixes for cache-capable providers.
- Record actual cache-read tokens.
- Use provider continuation state only if exposed and verified.
- For stateless providers, build a fresh self-contained follow-up pack.
- Add task capsules and short previous-answer handoffs, marked non-authoritative.

### Files

```text
host/native/brain-native/src/compress/thread.rs
host/native/brain-native/src/compress/pack.rs
host/native/brain-native/src/compress/ledger.rs
host/claude/agents-rc/brain-*.md
tests/compress/threads/
```

### Stop/rethink if

- No provider supports caching or continuation and thread complexity does not improve pack relevance.
- Handoff summaries create factual drift.
- Thread contamination occurs between unrelated tasks.

---

## Stage 6 — Main-session optimized file tools

**Effort:** 5–8 days  
**Behavior change:** Preferential instructions; enforcement remains opt-in

### Work

- Ship `brain compress read/grep/tree`.
- Add exact-range, outline, changed-since, and query modes.
- Add observe-only metrics for oversized built-in Reads.
- Add optional PreToolUse guard for large unrestricted Read calls.
- Do not add MCP schemas.

### Files

```text
host/native/brain-native/src/compress/{pack,outline}.rs
host/claude/hooks/brain-pre-file.sh
host/claude/routing-rc.md
host/claude/brain-ops.md
host/install.sh
tests/compress/file-tools/
```

### Stop/rethink if

- Claude ignores the preferred tools often enough that savings are negligible.
- Bash tool overhead exceeds saved context for typical files.
- Enforced denial causes repeated tool failures.

If this remains a dominant unresolved surface, evaluate a dedicated plugin/tool replacement as a separate project.

---

## Stage 7 — Prompt hygiene and schema audit

**Effort:** 2–4 days

### Work

- Reduce always-loaded injected docs to a concise index.
- Move detailed operations and uncommon cases to on-demand files.
- Deduplicate consult foreground/background rules.
- Shorten agent descriptions and bridge boilerplate.
- Add prompt-size budgets to tests.
- Add `brain compress doctor` reporting for enabled MCP servers and approximate schema bytes.

Suggested budgets:

```text
routing-rc.md: <= 700 estimated tokens
brain-ops always-loaded portion: <= 300
consult policy always-loaded portion: <= 250
```

Do not compress away safety or routing distinctions merely to hit a budget.

### Files

```text
host/claude/routing-rc.md
host/claude/brain-ops.md
host/claude/consult-*.md
host/claude/agents-rc/*.md
tests/compress/prompt-budgets/
```

---

## Stage 8 — Semantic compression experiment

**Effort:** 5–7 days  
**Default:** Off

Proceed only if Stage 5 metrics show repeated artifacts over 12k tokens and deterministic techniques are insufficient.

Implement as a separately flagged experiment:

```bash
brain compress summarize ARTIFACT \
  --model luna \
  --target-tokens 1500 \
  --purpose docs
```

Record the summarizer’s provider usage as a cost, not as free compression.

Stop immediately if:

- Total weighted tokens increase.
- Recovery or correction rates exceed deterministic modes.
- Summaries are used as edit sources.
- Sensitive material reaches the summarizer.

---

# 7. What not to build

1. **Do not rebuild RTK’s command filter catalog.**
   - Depend on pinned RTK.
   - Brain-native owns policy, safety, storage, and metrics only.

2. **Do not write a universal shell parser or rewrite arbitrary shell programs.**
   - Handle safe simple argv commands.
   - Report complex missed opportunities.

3. **Do not claim PostToolUse compresses Read/Grep/Glob unless the original result is proven absent from the model-visible transcript.**
   - Appending compact context is not compression.

4. **Do not build an MCP-based replacement for file tools in v1.**
   - It adds tool schemas to every main request.
   - Use CLI plus optional guards first.

5. **Do not build a local LLM stack on the droplet.**
   - The RAM, maintenance, latency, and quality tradeoff are poor.

6. **Do not create a custom token-oriented encoding that models must learn.**
   - Use exact ranges, outlines, escaped TSV, JSONL, and plain text.

7. **Do not semantically summarize every remote response.**
   - Ask for concise output at generation time.
   - Use exact deterministic post-filters afterward.

8. **Do not treat local artifact handles as remote memory.**
   - Handles only support the current request protocol or a second local-mediated call.

9. **Do not fork or replace `cli-proxy-api` to emulate conversation state in v1.**
   - Use real cache/continuation capabilities if exposed.
   - Otherwise remain stateless and self-contained.

10. **Do not compress tool inputs, patches, edit text, or user/system instructions.**

11. **Do not automatically compact the main Claude conversation.**
   - Use Claude Code’s built-in compaction.
   - At most, show a statusline warning and document `/compact`.

12. **Do not show dollar savings derived from bytes/4.**
   - Provider response usage is ground truth for consultations.
   - Everything else must be labeled estimated.

13. **Do not preserve raw artifacts forever.**
   - Pin active sessions, use bounded retention and quota, and bypass compression if recovery cannot be guaranteed.

---

# Initial default configuration

```toml
enabled = true
mode = "guarded"

[artifact]
retention_days = 14
post_thread_retention_days = 7
max_store_bytes = 2147483648
max_remote_recovery_rounds = 2

[shell]
enabled = true
backend = "rtk"
rewrite_complex_shell = false
unknown_nonzero = "bypass"

[consult]
prompt_enabled = true
response_enabled = true
semantic_enabled = false
thinking_to_stdout = false
opaque_prompt_mode = "lossless-only"
thread_mode = "capability"

[file_tools]
enabled = true
read_guard = "observe"
large_file_bytes = 49152
large_file_lines = 800

[sensitive]
remote_default = "deny"
semantic_default = "deny"
```

# V1 completion criteria

V1 is complete after Stages 0–4A when all are true:

- `brain compress off` reliably restores current behavior.
- Shell compaction uses RTK and has exact raw recovery.
- Bridge agents no longer read and inline whole files by default.
- `brain-ask` records real provider usage.
- Consultation raw output and thinking do not automatically enter Claude’s context.
- Every lossy view starts with a valid artifact handle.
- Remote omitted context can be requested through a bounded protocol.
- No compression path modifies patches, edit source, commands, user instructions, or sensitive files.
- Stats distinguish provider-ground-truth usage from estimated downstream reduction.

---

# Appendix — evaluation backlog: other token-saving techniques (post-RTK)

Requested 2026-08-19: after RTK integration lands, evaluate other popular tools and fold the
worthwhile ideas into the subsystem. They split into categories that do NOT all compete with
what we're building — several are orthogonal and cheap to adopt alongside it.

## A. Behavioral / output-shaping (change what the model DECIDES or WRITES)
These are skills/prompt-level, near-zero implementation cost, orthogonal to the compression
engine. They reduce *generated* output tokens (the part post-filtering can't).
- **Ponytail** — a Claude Code skill: a "lazy senior dev" that writes the least code that
  solves the problem (no speculative abstraction, prefer stdlib). Advertised −22% tokens /
  −20% cost; **JetBrains' 80-task A/B measured −10.3% cost (p=0.004), −15% code**, savings
  concentrated on 300+ line tasks, near zero on small ones, no quality loss. Honest, modest,
  free. Candidate: adopt as a skill for the main brain and as a response-profile hint for
  bridges. Note the advertised-vs-measured gap (~2x) — matches our measurement discipline.
- **Caveman** — Claude Code skill that rewrites verbose agent responses into terse output;
  reports ~65% output-token reduction. Overlaps our §3 response contracts; mine for prompt
  wording, don't add as a dependency.

## B. Tool-output compression (SAME category as RTK — our core engine)
- **Headroom** — drop-in compression layer for tool outputs, logs, files, RAG chunks;
  reversible; 60–95% fewer tokens on JSON, ~20% for coding agents; ships as library, proxy,
  OR MCP server. The most direct RTK alternative. Evaluate head-to-head with RTK on our
  actual command mix before committing to RTK long-term (both, or pick one).
- **LeanCTX** — local Rust binary, 60–90% fewer tokens. Compare.
- **TokenShift** — Rust binary, 17 techniques (dedup, CLI trimming, prompt compression, image
  rightsizing), 12–21% measured. Mine the technique list; several map to our §3 table.

## C. Tool replacement / delegation
- **WOZCODE** (already summarized) — replaces built-in file tools; cheap-model (Haiku)
  exploration subagent. Requires an account (rejected — brain stays local). But Stage 0 H1
  showed we can clamp Read transparently via PreToolUse WITHOUT a tool replacement, and the
  brain already has cheap-model bridges (luna) for the delegation idea. Reimplement the good
  parts locally, don't adopt.

## D. API-level (free, provider-side — evaluate independently of the engine)
- **Anthropic context compaction** — `compact-2026-01-12` beta header condenses conversation
  history server-side (one report: 132k -> 2k tokens). This targets token-map surface #8
  (main conversation history), which the plan explicitly declined to touch by hand. If the
  brain's own session can set this header (via Claude Code config), it may be the single
  biggest main-session win and costs us nothing to build. HIGH-PRIORITY probe — check whether
  Claude Code 2.1.x exposes it. Verify against docs via the claude-api skill before relying.

## Evaluation method (reuse §5)
Do NOT trust advertised numbers (Ponytail was ~2x over). For each candidate: run it through
the paired frozen corpus (§5.3), measure provider ground-truth usage, and record measured vs
advertised. Adopt only what beats its own overhead. Sequencing: finish RTK (Stage 2) first,
then B (Headroom head-to-head), then A (Ponytail/Caveman as skills), then D (compaction probe).

---

# Implementation status (updated 2026-08-19)

- **Stage 0** (capability spike) — DONE. Results: docs/compression-capabilities.md.
- **Stage 1** (native foundation + observe-only ledger) — DONE. Async tokio+reqwest crate
  `host/native/brain-compress`; brain-ask drop-in; token-savings accounting.
- **Stage 2** (RTK-backed Bash compression) — DONE. `brain-compress shell` + PreToolUse
  hook; verified live (git log 10,881→185 B to the model, exact recovery). RTK used as a
  filter library via `rtk pipe` (not its tee); mutate-only hook composes with the deny-only
  poll-guard. See host/native/brain-compress/STATUS.md.
- **Stages 3, 4A, 6, 7** — DONE. Response profiles; context packs (--context-file); file
  tools + Read guard (verified live); ops docs. PR feature-complete. 4B/5/8 deferred
  (build risk / H4-unverifiable / off-by-default)...
  so remote answers reach the brain compact.

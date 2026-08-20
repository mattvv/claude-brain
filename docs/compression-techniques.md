# Compression techniques beyond RTK — adoption plan (post-v0.2.1)

> Scoped with `gpt-5.6-sol` (effort high) on 2026-08-20. Decision-ready verdicts for the
> "other techniques" backlog in [compression-plan.md](compression-plan.md) Appendix
> (categories A behavioral, B compressors, C tool-replacement, D newer), constrained by the
> measured facts H1–H7 in [compression-capabilities.md](compression-capabilities.md) and the
> shipped `brain-compress` architecture (droplet/native/brain-compress/STATUS.md).
> Status: **proposal, nothing implemented.**
>
> **Scope boundary:** this document deliberately EXCLUDES the two items owned by the
> measurement track in [compression-next.md](compression-next.md): P1 (the frozen-corpus A/B
> measurement harness) and P2 (the Anthropic server-side context-compaction probe, the
> `compact-2026-01-12` beta header for main-conversation history). Those are designed and
> built elsewhere. This plan references the harness as the tool that PROVES each technique but
> does not design it.
>
> **Trust rule:** advertised numbers are not planning numbers. Ponytail's advertised figures
> ran ~2x over its independently measured result. Every verdict below is gated on measured
> provider-ground-truth usage, not vendor claims.

---

# Decision summary

| Technique | Verdict | Role relative to RTK |
|---|---:|---|
| Ponytail | **BUILD** | Orthogonal; reduces generated implementation output |
| Caveman | **BUILD** | Orthogonal; reduces generated narrative output |
| Headroom | **MINE** | Potential generic complement; not a current replacement |
| LeanCTX | **MINE** | Benchmark challenger; not a current replacement |
| TokenShift | **MINE** | Source of narrow ideas; do not adopt the bundle |
| WOZCODE | **MINE** | Product skipped; retain only local delegation/retrieval ideas |
| Content-addressed duplicate-result elision | **BUILD** | Local complement for repeated tool results |
| Schema-aware JSON/NDJSON projection | **BUILD** | Local generic complement for structured output |
| Token-oriented object notations such as TOON-style formats | **SKIP** | Unfamiliar encoding conflicts with the design constraints |

Production default remains RTK for its verified command filters. Do not add an MCP server, resident proxy, or opaque prompt compressor.

---

## A. Behavioral/output-shaping

### Ponytail

**Verdict: BUILD — implement the operational rules locally; do not depend on the external skill package or its persona branding.**

- **Hook point:**  
  For the main brain, add one short, conditionally injected instruction block in a new `brain-output-policy.md` beside `routing-rc.md` and `brain-ops.md`; the existing main-session document injector must omit it when the global or behavioral-surface kill switch is off. For bridges, add `minimal-implementation` to `ask.rs::profile_instruction()`, expose it through the existing `brain-ask --response` parsing in `cli.rs`, gate it in `config.rs`, and record the exact profile in `ledger.rs` while retaining the `guarded` experiment arm. Recommended bridge instruction:

  > Implement only the requested behavior with the smallest correct change. Do not add speculative abstractions, helpers, dependencies, configurability, or future-proofing. Prefer the standard library and existing project patterns. Return only a unified diff or minimal snippets tagged with file:line; explain only non-obvious choices in one line.

- **Fidelity rules:**  
  Explicit user requests for extensibility, abstraction, detailed explanation, full files, or a particular format override the minimalism hint. The policy must never alter user/system/safety/routing instructions, exact replacement text, patch input, command input, or supplied code. It may reduce newly generated code, but must not post-filter generated patches or remove added/deleted diff lines. Required validation, safety caveats, diagnostics, and requested evidence remain mandatory. If `stop_reason=max_tokens`, emit the provider response unchanged, classify the trial as unsuccessful, and claim zero savings. Recovery headers do not apply because this changes generation rather than emitting a lossy view of an existing source.

- **Expected win:**  
  This attacks **generated output tokens** and, secondarily, response/transcript bytes. It does not reduce current-call input tokens; the extra instruction slightly increases them. The external independent result—10.3% lower cost and 15% less code, concentrated on 300+ line tasks—is a useful prior, but it is not a local token guarantee and should not be translated into a claimed output-token percentage. Working expectation: near zero on small fixes, potentially material on large implementation/refactor tasks. Any downstream input reduction from having less generated code in later turns is secondary and must be measured separately.

- **How to prove:**  
  Use the existing frozen-corpus harness to compare default, current `implementation`, and new `minimal-implementation`. Stratify by expected patch size, actual changed lines, new feature versus bug fix, language, framework-heavy versus standard-library-friendly work, and whether the prompt explicitly asks for extensibility. Measure authoritative provider `output_tokens`, added/changed lines, input-token overhead from the instruction, task/test success, patch applicability, omitted requirements, follow-up turns, and total tokens across retries. Promote it only where quality is noninferior and savings survive follow-up/rework costs.

- **Notes:**  
  Do not import the “lazy developer” persona verbatim; retain only smallest-correct-change, no-speculation, and prefer-existing-patterns rules. Do not make the bridge profile universal: the evidence predicts little benefit on small tasks. For the main brain, keep Ponytail and Caveman in one compact document rather than loading two permanent documents; H4 means prompt-cache savings cannot be assumed. A reasonable promotion gate is at least a measurable output-token improvement on large implementation tasks with zero statistically meaningful increase in failed or incomplete solutions.

### Caveman

**Verdict: BUILD — use a generation-time terseness contract, not a post-generation response rewriter.**

- **Hook point:**  
  Add the main-brain rule to the same `brain-output-policy.md`. For bridges, add a separate `terse` response profile in `ask.rs::profile_instruction()`, with CLI/config/ledger handling through `cli.rs`, `config.rs`, and `ledger.rs`. Recommended instruction:

  > Answer in the fewest words that preserve correctness, required evidence, and requested detail. Lead with the answer. Omit preamble, recap, narration, obvious explanation, and repeated prompt or code. Prefer bullets, file:line citations, or a minimal diff.

  Keep existing `concise`, `review`, `debug`, `implementation`, and `architecture` strings unchanged so the harness retains stable controls.

- **Fidelity rules:**  
  This must operate only at generation time. Do not generate a verbose answer and then run a second model/filter to shorten it: that cannot save the original generated tokens and may increase total tokens. Explicit requests for tutorials, rationale, exhaustive findings, full diagnostics, or exact text override terseness. It must preserve all requested findings, evidence, safety caveats, compiler diagnostics, and unique failures. It must not alter exact code or patch text after generation. A `max_tokens` response is emitted untouched, counted as a failed trial, and never claimed as compressed. Kill switches must suppress the appended bridge instruction and the main-session document injection.

- **Expected win:**  
  This reduces **generated output tokens** and response/transcript bytes. It does not reduce input tokens and adds a small prompt cost. The reported 65% reduction is not a planning number. Against an unconstrained verbose baseline, reductions may be substantial on narrative answers; against the already strong `concise`, `review`, `debug`, and `architecture` profiles, incremental gains may be small or zero. Expect the largest benefit for the main brain, which currently lacks an equivalent always-available output policy.

- **How to prove:**  
  Compare default versus existing `concise` versus new `terse`; comparing only against default would exaggerate incremental value. Stratify review, debugging, architecture, factual answers, implementation, explicitly detailed requests, and outputs with required citations or multiple findings. Measure authoritative output tokens, input overhead, required-fact recall, finding recall, citation correctness, patch correctness, user-visible response bytes, follow-up questions, retries, and aggregate tokens through task completion. A shorter first answer that causes another full consultation is not a win.

- **Notes:**  
  If `terse` fails to beat `concise` materially, do not retain a redundant public profile: use the existing profile and keep only the main-brain policy. Do not advertise 65%. A sensible bridge retention gate is a clear incremental output-token reduction over `concise` without reduced finding recall or increased follow-ups. The main-brain policy can still survive even if the bridge profile does not.

---

## B. Tool-output compressors

### Headroom

**Verdict: MINE — evaluate its transforms out of tree, but add no library, proxy, daemon, or MCP dependency now.**

- **Hook point:**  
  Any future experiment belongs after exact raw persistence in `shell.rs` and `files.rs`, at the same point where `shell.rs` currently invokes `rtk pipe --filter`. For context/RAG-like material, the only acceptable bridge hook is in `ask.rs` after the context source is persisted and before request assembly. `artifact.rs` remains the authority for raw storage and recovery; `ledger.rs` records measured bytes and, when the result is actually sent to a provider, provider-ground-truth input usage. Do not integrate the MCP form because its schemas would burden every applicable model request.

- **Fidelity rules:**  
  Headroom’s claim of reversibility does not exempt it from the brain contract. The raw source must first be persisted by `artifact.rs`; brain-compress, not Headroom, emits the required header, trailer, omission markers, and recovery command. Persistence failure means warned passthrough or strict fail-closed. Bypass credentials, binary data, patches/replacement text, command inputs, edit-source files, diagnostics requiring exact preservation, and all unknown non-zero command outputs. Preserve exit code and stderr. A compressor error must cause honest passthrough. Never stack Headroom after RTK: select one view from the raw source.

- **Expected win:**  
  The possible win is fewer **tool-result bytes** and fewer **provider input tokens** when those results enter a subsequent prompt. It cannot reduce generated output tokens. The 60–95% JSON and approximately 20% coding claims are untrusted until reproduced. Relative to raw JSON it may be useful; relative to RTK on verified git/test/compiler filters, the expected incremental gain is uncertain and may be negative. Its proxy/MCP forms also add operational or prompt overhead not reflected in compression claims.

- **How to prove:**  
  Run Headroom as an isolated candidate against the harness corpus without adding it to production. Stratify homogeneous JSON, nested JSON, NDJSON, logs, source files, RAG chunks, high-entropy text, RTK-covered commands, RTK-uncovered commands, successful commands, known test/compiler failures, unknown non-zero outputs, secrets, and diffs. Measure provider input tokens when fed to representative models, raw/view bytes, exact-value question answering, unique-failure retention, recoveries, latency, peak RSS, startup cost, and malformed-output behavior. Compare directly against raw, RTK, and the proposed local JSON projection—not against advertised figures.

- **Notes:**  
  Headroom is a potential **generic complement**, not a wholesale RTK replacement. Revisit `ADOPT` only if there is a pinned, locally executable, network-free form with an acceptable license and prebuilt artifact. A library is preferable only if it is a small Rust dependency; otherwise a one-shot CLI is safer than a resident proxy. Do not adopt the MCP form.

### LeanCTX

**Verdict: MINE — keep it as a benchmark challenger and source of transform ideas; do not ship the binary yet.**

- **Hook point:**  
  If evaluated, invoke its prebuilt binary as a one-shot filter from the post-artifact stage in `shell.rs` or `files.rs`. It must receive stored raw content on stdin and return only a candidate view on stdout. Selection, headers, passthrough, stderr handling, exit preservation, and ledger accounting remain inside brain-compress. Configuration would belong in `config.rs` as an experimental backend, not as the default.

- **Fidelity rules:**  
  All artifact, header/trailer, omission, recovery, error, credential, binary, diff, edit-source, and kill-switch requirements apply. Unknown non-zero command output is never sent through it. Known test output must preserve every unique failure and trace; compiler output must preserve all diagnostics. The binary must not receive system/user instructions or command arguments/stdin. If the output is opaque, requires a decoder prompt, cannot identify omissions, or changes exact values, it fails the contract regardless of compression ratio.

- **Expected win:**  
  Potentially fewer tool-output bytes and downstream input tokens; no generated-output-token savings. The claimed 60–90% is only an advertisement. There is no supplied independent local measurement, so the production expectation should be “unknown.” Its Rust implementation and local-binary packaging are operational positives only if prebuilt artifacts exist; they do not establish fidelity or model comprehension.

- **How to prove:**  
  Use the same corpus strata as Headroom, with additional attention to startup time, peak RSS, binary size, malformed UTF-8, very large files, and behavior under low-memory/swap pressure. Measure provider input usage, not bytes alone, because compact syntax may tokenize poorly. Test answer fidelity on exact numbers, paths, line numbers, JSON keys, failure traces, and code excerpts. Compare filter-by-filter against RTK rather than using one aggregate percentage.

- **Notes:**  
  This is a possible **generic complement or per-filter replacement**, never an automatic global replacement. Obtain a prebuilt CI artifact; do not compile a heavy dependency tree on the droplet. If no pinned prebuilt binary and verifiable license are available, stop at MINE.

### TokenShift

**Verdict: MINE — extract only contract-compatible techniques; do not adopt the 17-technique bundle.**

- **Hook point:**  
  Exact-line/block deduplication and safe CLI trimming can be reimplemented in `shell.rs` and `files.rs` after `artifact.rs` persistence. Prompt compression would nominally hook into `ask.rs`, but it must not be implemented against user/system/routing text. Image rightsizing would also sit in `ask.rs` request assembly, but is disallowed by the current “never compress or mutate binary data” rule. Any mined technique gets its own config flag and ledger label rather than a single broad TokenShift switch.

- **Fidelity rules:**  
  Deduplication may collapse only exactly identical, clearly non-diagnostic repetitions and must mark every omission. It must preserve all unique failures, traces, diagnostics, exact values, diff additions/deletions, replacement text, and edit-source lines. Prompt-compression techniques may not touch instructions; lossy compression of arbitrary context remains disallowed unless the raw source is persisted, recoverable, clearly marked, and treated as discovery-only where editing is possible. Image mutation is out of scope under the binary-data prohibition. All surfaces obey persistence failure, recovery, errors, and kill switches.

- **Expected win:**  
  The supplied 12–21% measured range is stronger evidence than an advertisement, but it applies to TokenShift’s combined corpus and technique bundle—not to every transform or to claude-brain. Safe dedup/CLI trimming could reduce tool-result bytes and downstream input tokens on repetitive logs. Prompt compression might reduce input tokens but has unacceptable fidelity risk on unrestricted text. Image rightsizing would affect image input tokens, but it is currently prohibited. None of these reduce generated output tokens.

- **How to prove:**  
  Test mined techniques independently so their effects are attributable. Stratify repetitive successful logs, repeated progress lines, high-entropy output, test failures, compiler diagnostics, JSON, diffs, code, secrets, and already compact RTK results. Measure provider input tokens, view bytes, unique-information recall, exact-value accuracy, omission correctness, recoveries, and latency. Never report the external 12–21% as a local result or sum individual technique percentages.

- **Notes:**  
  TokenShift is **MINE-only**, not an RTK replacement. The bundle’s breadth is a liability because several techniques cross prohibited surfaces. The most promising idea is exact repetition suppression, implemented locally and narrowly. Do not expose the binary to complete prompts, images, or arbitrary tool traffic.

### RTK replacement policy

Do not make a global backend choice. Select the best verified filter per output class, directly from persisted raw content.

A candidate may replace RTK for a particular filter only when all of the following hold:

1. **Token result:** At least 10% lower provider-ground-truth input tokens than RTK on that filter’s eligible corpus, with no material p90 regression. Bytes are secondary.
2. **Quality:** Noninferior task-answer quality and exact-value recall, with zero loss of unique failures, traces, diagnostics, diff changes, or edit-source material.
3. **Recovery:** Exact raw recovery remains controlled by `artifact.rs`; recovery frequency does not erase the measured gain.
4. **Operational behavior:** Exit codes and stderr remain correct; compressor crashes produce passthrough; no network access, daemon, proxy, or MCP schema is required.
5. **Resource envelope:** Pinned prebuilt binary, acceptable license, peak RSS no higher than roughly 128 MiB under serial operation, and p95 compression overhead no more than the greater of 100 ms or 10% of command runtime.
6. **Model readability:** No proprietary decoder instructions or unfamiliar encoding required.
7. **Maintainability:** The replacement removes or materially reduces code/operations rather than adding a second fragile path.

Remove RTK globally only if another backend wins across essentially every currently verified RTK filter and simplifies operations. The more likely outcome is RTK for semantic command filters plus one local generic structured-output filter.

---

## C. WOZCODE

**Verdict: MINE — skip the product and tool replacement; retain only local, explicit exploration delegation patterns.**

- **Hook point:**  
  Do not replace built-in Read or file tools. Continue using `hook.rs`’s `pre-read` enforcement for bounded ranges/deny-with-guidance, `files.rs` for `read --outline/--query/--lines`, `grep`, and `tree`, and `ask.rs` plus existing `--context-file/--context-range` for consultations. If a local exploration path is added, route an explicit discovery-only task through the existing luna bridge using `ask.rs`, preferably with `--response concise` or `terse`; add routing guidance to `routing-rc.md`, not a new tool protocol.

- **Fidelity rules:**  
  Exploration summaries are discovery aids, never edit sources. The cheap agent must cite `file:line`, and the main model must retrieve exact current lines before editing. Exact source must already be immutable/addressable or persisted before a lossy projection is given to a model. Never delegate credentials, binary files, patches, replacement text, or system/user/routing instructions. Do not silently rewrite unrestricted built-in Read into an outline because H1/H2 show that the hook cannot replace the result with a compliant lossy view; bounded reads and deny-with-guidance remain the safe options. All bridge kill switches apply.

- **Expected win:**  
  This is primarily **model-tier delegation**, not compression. It may reduce input tokens sent to the main/expensive model and reduce the bytes returned to its transcript by returning concise findings instead of whole files. It adds luna input and generated output tokens, so aggregate provider tokens may stay flat or increase. It does not inherently reduce generated output tokens, and no cost claim should be made without separate per-model usage.

- **How to prove:**  
  Stratify repository exploration, symbol location, dependency tracing, bug localization, and tasks that immediately lead to edits. Measure main-model input/output usage, luna input/output usage, aggregate tokens, latency, citation accuracy, localization success, exact-line retrieval before editing, follow-up/recovery rate, and final task quality. Report main-model displacement separately from total-token change.

- **Notes:**  
  The external account requirement makes the WOZCODE product a hard **SKIP**. H1 and the existing luna bridge already provide the two useful ideas without replacing trusted tools. Do not build a generic autonomous exploration subagent unless the harness shows that main-model token displacement survives the added luna calls and latency.

---

## D. Additional backlog additions

No newer external compressor currently has enough verified evidence to justify another production dependency. The worthwhile additions are narrow, architecture-native techniques that exploit `artifact.rs` and standard formats.

### Content-addressed duplicate-result elision

**Verdict: BUILD — add deterministic duplicate suppression for brain-compress-owned tool outputs.**

- **Hook point:**  
  Extend `artifact.rs` with lookup by `raw_sha256`, then check for exact duplicates in `shell.rs` and `files.rs` after raw persistence and before RTK or other view generation. If `hook.rs` exposes a stable session identifier, scope elision to the active session and record the previous artifact reference in `ledger.rs`. The emitted view should contain the standard recovery header, a human-readable “identical to artifact …” marker, and the required omitted-line trailer.

- **Fidelity rules:**  
  Apply only to byte-identical successful text output. Do not apply to errors, unknown non-zero output, credentials, binary data, diffs, replacement text, or edit-source content. Raw persistence is mandatory even if an older artifact with the same hash exists, unless the artifact store can prove the older object is still present and immutable. The current output’s exit code and stderr remain unchanged. If the model lacks access to `brain compress show`, do not emit only a reference. Recoveries subtract from savings, and all kill switches apply.

- **Expected win:**  
  On an exact duplicate, the tool-result view can shrink by well over 90%, reducing transcript bytes and future model input tokens. Corpus-wide savings may be near zero if duplicate outputs are rare. It does not reduce generated output tokens. It is most promising for repeated status, tree, grep, test, and configuration reads within a long session.

- **How to prove:**  
  Stratify exact repeats, near-repeats, repeats separated by edits, repeats across sessions, error outputs, and edit-source reads. Measure duplicate incidence, provider input tokens, emitted bytes, false duplicate rate, artifact availability, recovery frequency, added latency, and whether models unnecessarily recover already known content. Evaluate session-scoped and global lookup separately; do not use global elision if it increases recoveries because the prior content is not in active context.

- **Notes:**  
  Start with exact whole-result duplicates only. Do not begin with fuzzy or semantic deduplication. If stable session identity is unavailable in hook JSON, limit the first version to within-process/bridge request assembly or defer session-aware elision rather than inventing unreliable TTY/time heuristics.

### Schema-aware JSON/NDJSON projection using standard syntax

**Verdict: BUILD — implement a narrow local structured-output filter instead of adopting a broad external compressor.**

- **Hook point:**  
  Add a small `structured.rs` module called from `shell.rs` and `files.rs` after `artifact.rs` persistence. Expose an explicit `brain compress json` surface through `cli.rs`; later allow `shell.rs` auto-selection only for successful output that parses unambiguously as JSON/NDJSON. Use existing/lightweight Rust JSON support and standard minified JSON or Markdown tables—no custom encoding. Add per-surface controls in `config.rs` and measured-byte records in `ledger.rs`.

- **Fidelity rules:**  
  Generic mode must preserve every scalar value without rounding, truncation, key dropping, null dropping, or deduplication. Table projection is allowed only for homogeneous arrays of scalar records; otherwise use standard JSON or passthrough. Field/row selection must be explicit or tied to a verified known schema, with inline omission markers and the required trailer. Always persist exact raw bytes first and mark formatting/projection views as lossy/recoverable. Bypass secrets, patches, replacement text, source being edited, binary data, malformed JSON, and unknown non-zero output. Honest passthrough applies whenever token or byte gain is absent.

- **Expected win:**  
  This can reduce structured tool-result bytes and downstream input tokens, especially for repeated-key arrays. It cannot reduce generated output tokens. Minified JSON may reduce bytes while leaving token counts flat or even worse, so no gain should be assumed. Standard tabular projection is the likely positive case; nested/high-entropy JSON may see no benefit. It targets Headroom’s most plausible niche without introducing a proxy or unfamiliar representation.

- **How to prove:**  
  Stratify flat arrays, deeply nested objects, NDJSON logs, sparse fields, long strings, numbers requiring exact precision, escaped text, mixed schemas, secrets, malformed input, and known command outputs. Compare raw pretty JSON, minified JSON, standard table projection, RTK where applicable, and external candidates. Measure provider input tokens per vendor/model, exact key/value question accuracy, row association, bytes, latency, peak RSS, recovery rate, and passthrough frequency.

- **Notes:**  
  Do not implement a full query language or pull in a heavy parser initially. A field allowlist and dot-path selector are sufficient. Auto-detection should come only after explicit-mode results are proven. If the harness shows that minification harms tokenization, retain only the homogeneous-table path.

### Token-oriented object notations such as TOON-style formats

**Verdict: SKIP — do not make models learn another compact wire syntax.**

- **Hook point:**  
  None in production. At most, an out-of-tree harness comparison could place such an encoding between persisted JSON and `ask.rs` request assembly. It must not be added to `shell.rs`, `files.rs`, system prompts, or main-session instructions.

- **Fidelity rules:**  
  A custom or unfamiliar notation risks changing exact values, confusing nested associations, requiring decoder instructions, and violating the prohibition on proprietary encodings models must learn. Even if reversible by a library, the brain artifact/header/recovery contract still applies. It may never carry instructions, patches, credentials, binary data, or edit-source text.

- **Expected win:**  
  The only plausible direct benefit is reduced structured-data input tokens and bytes. It cannot reduce generated output tokens. Decoder instructions, schema explanation, model errors, and recovery calls can erase nominal token savings, especially under H5’s fixed per-call overhead. Standard JSON and tables provide a safer baseline.

- **How to prove:**  
  If evaluated solely to validate the skip decision, compare provider input usage and exact-value comprehension against raw JSON, minified JSON, and standard tables. Stratify nested data, arrays, nulls, Unicode, escaped strings, large numbers, and tasks requiring precise row/key association. Any material comprehension regression or need for explanatory prompt text is disqualifying.

- **Notes:**  
  Mine the general observation that repetitive JSON keys are expensive; implement that insight through the local standard table projection instead. Do not add the notation, its schema, or a decoder to recurring prompts.

---

# Recommended sequencing

1. **Keep RTK unchanged as the production default.**  
   Do not mix adoption work with `rtk rewrite` parser expansion; that is a separate RTK coverage improvement and should retain its own measurements.

2. **Ship Ponytail-derived behavior first, experimentally.**
   - Add the compact main-brain instruction block.
   - Add `minimal-implementation` in `ask.rs::profile_instruction()`.
   - Preserve the current `implementation` profile as the control.
   - Promote only for task strata where output-token savings and quality both hold.

3. **Ship Caveman-derived behavior second.**
   - Add `terse`, keeping `concise` unchanged.
   - If it does not beat `concise` incrementally, remove the redundant bridge profile while retaining the main-brain output policy.
   - Never add a second-pass rewriting call.

4. **Build the local schema-aware JSON/NDJSON filter.**
   - Begin with explicit `brain compress json`.
   - Start with minified standard JSON and homogeneous scalar tables.
   - Add no generic automatic field deletion.
   - Promote auto-detection only after measured model-token and comprehension results.

5. **Build exact duplicate-result elision.**
   - Whole-result byte identity only.
   - Prefer active-session scope.
   - Do not implement fuzzy similarity or semantic deduplication in the first wave.

6. **Run external candidates as out-of-tree challengers, in this order:**
   1. Headroom, because it is the most direct generic/JSON competitor.
   2. LeanCTX, because a local prebuilt Rust binary could fit operationally.
   3. TokenShift techniques individually, not the bundled binary.
   
   None enters production until it crosses the RTK switch gates. Never stack candidate output on top of RTK output.

7. **Mine WOZCODE only after the direct compression work.**
   - Use existing luna and context ranges for an explicit discovery-only route.
   - Do not replace built-in tools.
   - Proceed only if the measured reduction in main-model context justifies additional luna tokens and latency.

8. **Deployment discipline for H7:**
   - Make Rust changes in the development checkout at `droplet/native/brain-compress`.
   - Build release/prebuilt binaries in CI, not on the constrained droplet.
   - Deploy the pinned binary to the installed tree only after harness acceptance.
   - Keep the main-brain policy document’s source-of-truth and installed copy explicit; do not hand-edit only the installed tree.
   - External candidate binaries must likewise be downloaded as pinned CI artifacts rather than built on the droplet.

---

# Open questions

1. **Main-session injection and kill switch:** What component currently loads `routing-rc.md` and `brain-ops.md`, and can it conditionally omit `brain-output-policy.md` when `DISABLED`, `BRAIN_COMPRESS=0`, or the behavioral surface flag is off? Do not make the policy always-on until this is reliable.

2. **Profile composition:** Should `brain-ask` eventually support a task profile plus an orthogonal style modifier—such as `--response implementation --style minimal`—or are the two new standalone profiles sufficient? Start with standalone profiles to avoid expanding the CLI before measurements.

3. **Main-brain usage ground truth:** Is authoritative provider usage available for main-session responses, or only for `brain-ask` consultations? If unavailable, report main-session transcript bytes and quality without estimating tokens.

4. **Session identity for duplicate elision:** Does the Claude Code hook payload expose a stable session/conversation ID? If not, avoid global duplicate suppression until a reliable scope exists.

5. **Artifact retention guarantee:** Can `artifact.rs` guarantee that a hash-referenced prior artifact remains available for the full session and ledger retention period? A duplicate reference is unsafe if garbage collection can remove its source.

6. **Credential detection:** Is there a sufficiently conservative shared credential detector before raw output is handed to any external candidate or structured projection? Contract-sensitive surfaces should default to passthrough on uncertainty.

7. **External candidate facts:** Headroom and LeanCTX still need verified license, version pinning, prebuilt architecture support, offline behavior, telemetry/network behavior, output grammar, and peak-resource data. Until those are known, their verdict remains MINE.

8. **Recovery access in bridges:** Can every model receiving a compact view actually invoke or request `brain compress show`? Duplicate-only references should remain on main-tool surfaces unless bridge recovery is explicitly available.

9. **JSON semantics:** Which known command schemas are common enough to justify verified field projection beyond semantically complete table rendering? Avoid generic field importance heuristics.

10. **Vendor-specific tokenization and usage:** JSON/table performance may vary materially by provider. Confirm any grok cache fields separately, but continue modeling prompt caching as absent unless authoritative per-call cache usage is exposed. Do not let unverifiable caching affect adoption decisions.

---

# Appendix — WOZCODE deep-dive (repo review, 2026-08-20)

Reviewed the actual `WithWoz/wozcode-plugin` repo (README, plugin.json, .mcp.json,
agents/{code,explore,recall,code-free}.md). It is a paid, account-gated, MCP-based
tool-REPLACEMENT plugin with PostHog telemetry — a different delivery model than ours
(local, no account, no MCP schema tax). Verdict per the appendix stands (skip the product),
but three of its *capabilities* are things we genuinely lack and should consider, reimplemented
locally under our fidelity/accounting rules:

1. **Symbol-aware code search (BUILD, upgrades deferred Stage 4B).** WOZCODE's `Search`/`Sql`
   run AST queries (compiled per-platform `queryparser` .node addons) returning dense
   defs/refs/callers — far better than our lexical `read --outline` + `grep`. It validates the
   delivery path we already chose (H7): ship prebuilt tree-sitter binaries from CI rather than
   building on the 1.9 GB droplet. Reconsider 4B as `brain compress read --symbols` /
   `brain compress refs <symbol>`, prebuilt in CI, with the same raw-persist + recovery contract.

2. **Cheap-model codebase `explore` (BUILD — highest-value, lowest-effort).** WOZCODE's
   `explore` agent runs on haiku, read-only, and returns a dense `Defs:/Refs:/Callers:` block
   whose output IS the caller's context. We have cheap models via the proxy but no equivalent
   for the brain's OWN repo navigation. Add a `brain explore` (or an RC-lane read-only bridge on
   luna) that scans and returns telegraphic findings, so the expensive brain never reads files
   itself. Prove with the measurement harness like any other surface.

3. **Session-history recall (EVALUATE).** WOZCODE's `recall` ranks/searches PAST Claude Code
   session transcripts and returns the one actionable item (a command/decision/fix) with a cite —
   distinct from our curated MEMORY.md. Attacks the conversation-history surface (#8) by making it
   retrievable instead of compacting it. Medium effort (needs a transcript index + ranker);
   treat recalled strings as untrusted data. Weigh against Anthropic's own compaction (H8) and
   Claude Code's built-in /compact before building.

Minor: live session+lifetime savings in the statusline (we have `brain compress savings`; wiring
it into droplet/claude/statusline.sh is small).

Not adopting: MCP tool replacement (schema tax on every request — rejected), account/telemetry,
batch-Edit (we never touch edit sources).

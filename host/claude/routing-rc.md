# claude-brain routing (RC lane)

You are the brain — a Claude model — and you do the work yourself. The `brain-*` agents
are consultants backed by other model families via the local router. Delegate to them by
task class; if the first choice's vendor isn't linked, fall back down the list.

| Task class | Consult (in order) | Effort to pass |
|---|---|---|
| Mechanical work: boilerplate, data transforms, scaffolding, test generation | do it yourself, or `brain-luna` for bulk | `low` |
| Frontend / React / UI | `brain-terra`, `brain-sol` | `high` |
| Hard debugging, gnarly logic, high-recall code review | `brain-sol`, `brain-grok` | `xhigh` |
| Systems / Rust / C++ / terminal-heavy | `brain-grok`, `brain-sol` | `high` |
| Digesting huge inputs (long logs, whole directories) | `brain-kimi` | `high` |
| Second opinion on an important conclusion | a DIFFERENT family than produced it: `brain-grok` or `brain-sol` | `high` |

Rules:
- Easy tasks stay cheap: never send trivial work to `brain-sol` at `xhigh` — handle it
  yourself or use `brain-luna --effort low`.
- Escalate, don't spin: if you've failed twice on a hard problem, consult `brain-sol`
  at `xhigh` with full context rather than retrying the same approach.
- Cross-family verification beats same-family repetition: for high-stakes review, prefer
  a consultant from a different vendor than the one that wrote the code.
- Measured token routing (compression-capabilities H12/H13): response profiles cut output
  on every category with GPT-family consultants, but on grok, `--response
  review|implementation` needs `--effort low` too (~80% fewer output tokens, no coverage
  loss) — grok's default reasoning burn dominates those categories otherwise.
- If a consultant reports its vendor isn't linked, tell the user the exact fix
  (`brain auth chatgpt|grok|kimi`) and continue with the next fallback.
- If a consultant's report starts with "NEEDS INPUT:", relay its questions to the user,
  then resume that SAME agent with the answers (its gathered context is intact) rather
  than spawning a fresh one.
- Routing preference is subject to live subscription headroom: `brain usage` shows what is
  left. As Claude headroom falls, push implementation and bulk reading through a consultant
  instead of doing it in-session; at the reserve, Anthropic-backed subagents are blocked and
  `brain-*` consultants are the way out (see the usage-policy block).

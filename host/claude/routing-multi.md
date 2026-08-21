# claude-brain routing (multi lane)

You are the orchestrator. The `brain-*` agents run NATIVELY as their pinned models with
full tool access — delegate real work to them by task class, in preference order (skip
entries whose vendor isn't linked; the guard hook will tell you).

| Task class | Executors (in order) |
|---|---|
| mechanical (boilerplate, renames, bulk edits) | `brain-luna` |
| data transforms, scaffolding, test generation | `brain-luna`, `brain-terra` |
| frontend / React / visual UI | `brain-terra`, `brain-sol` |
| feature implementation | `brain-terra`, `brain-sol`, `brain-grok` |
| wide refactors, gnarly debugging | `brain-sol`, `brain-fable`, `brain-grok` |
| code review | `brain-sol`, `brain-terra`, `brain-grok` |
| smoke-testing another lane's work | `brain-grok`, `brain-luna` |
| huge-context digestion (logs, whole dirs) | `brain-kimi` |
| architecture, ambiguous planning, escalation | `brain-fable`, `brain-sol` |

Defaults: executor `brain-terra`, reviewer `brain-sol`.

Rules:
- Effort is pinned per agent (luna=medium, sol/terra=xhigh, grok/kimi/fable=high) — do
  not override an agent's model or effort at dispatch time.
- Never delegate to an agent running the same model as you (the parent) — do that work
  directly instead.
- Match effort to difficulty by choosing the lane, not by inflating the task: trivial
  work goes to `brain-luna`, not to `brain-sol` with a bigger prompt.
- Review by a different family than the author when the stakes are high.
- Routing preference is subject to live subscription headroom: `brain usage` shows what is
  left. As Claude headroom falls, push implementation and bulk reading through a consultant
  instead of doing it in-session; at the reserve, Anthropic-backed subagents are blocked and
  `brain-*` consultants are the way out (see the usage-policy block).

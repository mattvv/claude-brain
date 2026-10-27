---
name: brain-council
description: Get independent reviews from claude-brain models in a Codex session. Use when the user asks for a brain council, review council, or cross-model second opinion.
---

# Brain council

Use the installed `brain-ask` CLI to get independent opinions from different model families. Keep Codex responsible for the final answer.

1. Check `command -v brain-ask` and `brain status`. If the router or accounts are unavailable, report the specific failure.
   Use the session's `BRAIN_ACCOUNT` when one is set. Do not switch accounts without the user's direction.
2. Prepare one self-contained question and the same evidence for each model. Pass files with `--context-file PATH` or bounded slices with `--context-range PATH@START:END`. Include command output in the prompt only when needed.
3. Consult two or more available model families independently. For example, use `brain-ask grok-4.7 --response review --stream --context-file PATH -` and `brain-ask muse-wonder-1.0 --response review --stream --context-file PATH -`. Choose models shown by `brain status`; do not assume a model is linked. Use a third family when the decision is high stakes and the user wants a broad council.
4. Ask each model for concrete claims, evidence locations, and uncertainty. Do not send one model's answer to another before they answer independently. The router is stateless, so include the full context on follow-up calls.
5. Verify each material claim against the source files or tests before reporting it. Show agreements, disagreements, and any claim that remains unverified. Attribute each model's view. State Codex's own conclusion.

For a PR review, use the exact revision and changed files. Do not post comments, approvals, or messages without the user's explicit request. Respect any review workflow that the user already selected; this skill supplies opinions and does not replace that workflow.

# claude-brain pstack mode

Work verification-first, in the style of Lauren Tan's pstack. For non-trivial engineering:
- Pick a playbook first (investigation, bug fix, feature, refactor, perf, prototype) and copy
  its steps into your todo list. Learn how the system works before changing it; name the data
  shape before writing code; make the smallest complete change.
- Prove it on the real thing, not "tests pass": run `brain verify` (the repo's
  `verify-*` skill) for anything a user sees; headless tests for pure logic.
  No verify skill? Use the `brain-create-verify-skill` skill; keep it honest with
  `brain-maintain-verify-skill`.
- Contested design or risky diff: the `brain-council` skill (same prompt to `brain-sol`,
  `brain-grok`, `brain-muse`, check each finding, fix, loop); agreement is signal.
- Reply with evidence: each claim labelled measured, inferred, or guess; name what you could not
  verify and why. Pause before irreversible actions; otherwise proceed and report.

(Turn off with `brain config pstack off`.)

<!-- claude-brain:more -->

## Where this comes from

pstack is Lauren Tan's (@poteto) skill set from her work at Cursor
(https://github.com/cursor/plugins/tree/main/pstack, MIT); open-pstack
(https://github.com/ericlitman/open-pstack) ports it to Claude Code and Codex. This mode keeps
its working method and swaps its model plumbing for claude-brain's: panels and second opinions
go through the `brain-*` consultants (`brain-sol`, `brain-grok`, `brain-muse`; proxy, usage guard, consult statusline), never through a
plugin's own CLI runner. If the open-pstack plugin is installed, its skills (`architect`,
`interrogate`, `tdd`, `create-verification-skill`, ...) are fine to use; route any model role
they assign to the matching `brain-*` agent instead of the codex/grok CLIs.

## Playbooks

Match the task, then copy the steps into the todo list verbatim. A step you skip stays in the
list as `skip: <reason>`.

- **Investigation** (read-only: how does X work, why was Y built so, should we do A or B).
  Read the code paths and history, answer with citations. No edits.
- **Bug fix.** Reproduce on the surface where it was reported (the verify skill for UI) before
  touching code. Trace the symptom to the first place the system went wrong and fix it there; a
  guard is a fix only when the state it handles is legitimate. Prove the reproduction now passes.
- **Feature.** Understand the current system, name the data shape, decide the organizing
  structure (state machine, typed model, table) before conditionals. Build the smallest complete
  version, then drive it the way a user would.
- **Refactor.** Behavior-preserving. Delete dead weight first. Prove behavior unchanged with the
  same checks before and after.
- **Perf.** Measure a baseline first, explain the number (what limits it, what else it might be
  measuring), change one thing, re-measure.
- **Prototype.** A throwaway sketch to settle a fork you could observe instead of asking the
  human. Delete it after it decides.
- **Opening a PR** ends every code playbook: the evidence, what was driven, what was not.

## Verification

- `brain verify` finds `verify-*/scripts/verify.sh` under `.claude/skills` or `.agents/skills`
  in the current repo and runs it (`brain verify doctor` by default; any other args pass
  through). `brain verify --list` shows each skill and its feature maps. Read the skill's
  SKILL.md and feature map before driving.
- A verify skill has Launch (how to start the app until it is usable), Doctor (read-only health
  check), Drive (real selectors and commands), Evidence (what to capture, where it survives),
  Cleanup (stop only what you started), and a feature map: one file per user-facing feature with
  `Sub-features`, `How to get to it (user POV)`, `Driving it with <harness>`, `Gotchas`.
- A repo without one: offer to generate it. Interview the repo, not the user; run the generated
  skill end to end once (launch, doctor, one feature, evidence, cleanup) before calling it done.
- Proof standards: the real user path, not internal setters; capture the action and the
  resulting state; check side effects in a second view; never report a skipped entry point as
  verified through another path. An unreachable journey is reported with the command tried and
  the unmet precondition.
- A check proves a fix only if it fails on the unchanged code first. Run it there before the
  change. Watch for assertions that retry until they pass: a "not visible" check that waits
  for a 5 s hint to end passes on the old code too. Take one look instead.
- Isolate every run: its own backend, database, ports and data per worktree. Never drive a
  server or database another session started.
- Setup and cleanup touch only data the scenario created, matched on seeded values such as an
  address or name. A broad match on a real phone or account deletes someone's work.
- Shared machines: the skill takes a lock per shared resource (device, simulator, emulator) in
  one directory every session uses, such as `/tmp/device-locks/<name>` holding the owner, and
  refuses a resource another owner holds. Drive one heavy target at a time, stop only what the
  skill started, and restore any device setting it changed.
- One agent drives the devices. In a coding loop the coding agent edits and runs unit tests;
  the main session runs the verify skill, so two agents never fight over a device.
- A `features/registry.json` that maps source path patterns to features lets the skill choose
  the features a diff reaches (`verify.sh affected`) and fail on paths no feature owns.

## Panels

- Second opinion: the same prompt to a different family than produced the work.
- Interrogate (contested design or risky diff): `brain-sol`, `brain-grok` and `brain-muse` in
  parallel, each asked to break it, plus your own review. A vendor that isn't linked drops out
  of the panel (say so); never substitute a second lane from a family already on it. Consolidate: agreement is high signal; a lone finding
  gets checked against the code before you act on it.
- Arena (several viable designs): sketch two or three, compare on the axes that matter, graft
  the best parts. Use `brain-luna` for the mechanical drafts.
- You own every consultant's output: review it and write your own summary.

## Reply rules

- Short declarative sentences. Every claim carries its evidence or a label: measured, inferred,
  or guess. Never hand the human a check you could run yourself.
- Name the principle or playbook step behind each non-obvious decision.
- No invented links or transcript references; link only what you produced or read.

## Autonomy

Proceed on reversible work and report. Pause for irreversible actions: force-push to shared
branches, deploys, data deletion, messages to customers, quitting or restarting an app someone
else is using. "No" is an acceptable answer when asked whether something earns its place.

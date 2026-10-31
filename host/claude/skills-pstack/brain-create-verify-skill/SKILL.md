---
name: brain-create-verify-skill
description: Generate a project-local verify skill that launches, drives and proves the real app (web, mobile, CLI, service, game) with evidence, plus a feature map and path registry, then run it end to end once. Use when a repo has no verify skill, when `brain verify` says "no verify skill", or for "make a verify skill", "create a verification skill", "how do we prove this works on the real app".
---

# Create a verify skill

Adapted from pstack's `create-verification-skill` (Lauren Tan, Cursor, MIT) and open-pstack. This version adds what real device runs taught: shared-machine locks, scenario-scoped cleanup, red-first checks and path-based feature selection.

A verify skill is the repo's scripted way to drive the real app and prove behavior. You write it for the next agent, who reads it cold, mid-task, and has never seen the app.

## 1. Interview the repo, not the user

Answer from the code. Ask the user only what you cannot observe.

- **Surface:** what does a user touch? Web UI, mobile app, CLI or TUI, API, desktop app, game. Pick the primary one and note the rest.
- **Run:** the repo's own dev command, ports, env vars, seed data and sign-in. Prefer a test sign-in path the repo already has for development (dev bypass token, access code, seeded test user) over a hosted login page. Never add a bypass, never point one at production, and never write a real password or token into the skill; read secrets from the environment.
- **Drive:** existing harnesses first (Playwright, Maestro, Detox, Appium, expect scripts, a debug port). Then a generic recipe: browser or CDP for web, PTY or tmux for CLI, plain HTTP for services.
- **Observe:** screenshots, accessibility trees, terminal transcripts, response bodies, logs, database rows, exit codes.
- **Isolate:** can a run get its own backend, database, ports and data? Where it can, the skill must use them. Where it cannot, say so and refuse to drive a shared instance.
- **Share:** which resources other sessions on the same machine also use (devices, simulators, emulators, fixed ports). These need locks.

If the checkout does not build or start, report it precisely. Fix it only with the user's go-ahead, and keep that fix separate from the skill.

## 2. Write the skill

Put it where the repo keeps project skills: `.claude/skills/verify-<app>/`, or `.agents/skills/verify-<app>/` in the Codex layout. `brain verify` finds both.

`SKILL.md` needs frontmatter (`name: verify-<app>`, and a `description` naming the app, surface and when to use it) and these sections, each grounded in what the interview found:

- **Launch:** the exact commands, from an empty data directory to a usable app, including migrations and seed data. "Ready" means usable, not "a process answers".
- **Doctor:** one read-only check: what runs, which build, who owns the port or device, whether sign-in works.
- **Drive:** real selectors and commands from this repo. Prefer stable handles (test IDs, ARIA roles, route paths, prompt strings) over coordinates.
- **Evidence:** what each run captures and where it survives: one folder per run with a `run.txt` (git head, dirty-file count, target, label, exit code), screenshots, logs.
- **Cleanup:** stop only what the skill started. Record each PID with its process start time (`ps -o lstart=`) in a state directory, and stop it only while both still match, so a reused PID is never killed. Release locks, restore any device or system setting it changed. Never delete evidence.
- **Helpers:** every script it ships is executable and shown with its exact invocation.

Ship `scripts/verify.sh` with at least `doctor` (read-only, exit 0 when healthy), because `brain verify` runs `verify.sh doctor` by default and passes other arguments through. A good shape is `doctor`, `up <part>`, `run <target> <feature>[:<case>]`, `affected [base]` and `down <part>|all`.

## 3. Seed the feature map

Create `features/README.md` plus one file per user-facing feature (start with the top 3 to 5). Each feature file has an H1, one paragraph of user-visible behavior, and exactly these H2s:

1. `Sub-features`: short IDs, one behavior each.
2. `How to get to it (user POV)`: every entry point, including ones runs do not drive yet.
3. `Driving it with <harness>`: `Preconditions:`, then each action paired with a command and an observable result.
4. `Gotchas`: traps that waste or invalidate a run.

Add `features/registry.json` that maps source path patterns to features. `verify.sh affected` reads it to choose the features a diff reaches, and fails on app paths no feature owns, so new code cannot skip verification silently.

## 4. Rules every generated skill follows

- **Red first.** A check proves a fix only if it fails on the unchanged code. The skill's docs say to run it there first. Avoid assertions that retry until they pass: a "not visible" check that waits out a 5 s hint passes on old code too. Take one immediate look instead.
- **Scenario-scoped data.** Setup and cleanup touch only rows the scenario created, matched on seeded values (an address, a name, a tag). A broad match on a real phone or account deletes someone's work.
- **Locks for shared resources.** One lock per device, simulator or fixed port in a directory every session uses (for example `/tmp/device-locks/<name>` holding `owner= since= purpose=`). Take it atomically (`mkdir`, or `set -o noclobber` before writing), so two sessions cannot both win. Refuse a resource another owner holds.
- **One heavy target at a time,** with cleanup between targets, so the machine keeps its memory.
- **One driver.** In an agent loop, the coding agent edits and runs unit tests; only the main session drives devices or browsers.
- **Never weaken a journey to make it pass.** A failing step is either map drift (fix the map) or a product regression (report it).

## 5. Traps to check for while proving it

Each costs a run when missed. Record the ones you hit in the feature's Gotchas.

- Tools that wait for the screen to settle (Maestro, WebDriverAgent's idle wait) stall for seconds on live views such as cameras, video or animation. Turn the wait off for those taps.
- Taps sent during a screen transition are dropped. For navigation taps, tap, wait for the next screen, and retry a bounded number of times. Never retry an action that creates or submits something; wait longer for it instead, or it may run twice.
- OS prompts: link confirmations ("Open in …?"), location, camera, microphone and photo permissions, low-storage warnings. Accept only the prompts the feature needs, only for the app under test, and list them in the feature's Gotchas. Never accept a prompt from another app.
- Persisted app state from earlier sessions (saved filters, markets, drafts, signed-in users) changes what the first screen shows. Reset only state the scenario owns (its test account, its seeded records, a filter it set). Never clear the device owner's drafts or sign-ins; work around them.
- Dev overlays (floating dev-menu buttons) cover controls on real devices.
- Physical devices sleep, lock or show a screensaver mid-run. Keep them awake during the run and restore the setting afterwards.
- A JS reload or hot restart in a dev build can crash natively. When the reload is harness setup (not the feature under test), keep the crash report as evidence, note it in Gotchas, and cold-start the app. When the crash is on the path under test, the run fails.

## 6. Prove the skill before handing it over

Run its own instructions end to end once: launch, doctor, drive one mapped feature, capture evidence, clean up. Confirm the evidence still exists after cleanup. Run cleanup after every failed attempt too. A skill that was never executed is a draft. If you proved it on a stand-in (a simulator instead of a phone), list what the stand-in skipped.

Point the user at `brain-maintain-verify-skill` to keep the map honest.

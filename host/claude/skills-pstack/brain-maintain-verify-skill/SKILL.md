---
name: brain-maintain-verify-skill
description: Keep a repo's verify skill and feature map honest. Read every feature from source, drive every feature live, fix map and harness drift in one change, and write each run's new lessons into Gotchas. Use for "audit the verify skill", "is the feature map still right", after a verify run hit a trap the map did not mention, or on a weekly upkeep pass.
---

# Maintain a verify skill

Adapted from pstack's `maintain-verification-skill` (Lauren Tan, Cursor, MIT). This version routes the source reading to `brain-*` consultants and adds a lessons step from Compound Engineering's habit of writing each lesson back into the repo.

A feature map rots as soon as the app changes. The unit of rigor is the feature: cover every feature file from source, and exercise every feature live.

## Outcomes

Pick one and say which:

- **clean:** every feature got source and live coverage, and nothing needs to change.
- **changed:** one change ships proven corrections to the map, skill docs or harness scripts.
- **blocked:** coverage could not finish, or a fix could not ship safely. Say exactly what blocked it.

## Edit scope

Edit only the verify skill's own directory (`SKILL.md`, `features/`, `scripts/`) and the harness files it owns. Never change product code here. App behavior that is broken is a product regression: report it, and do not hide it in the map.

## Pass

1. **Locate the target.** Run `brain verify --list`. Several skills: ask which. None: stop and use `brain-create-verify-skill`.
2. **Index hygiene.** Read `features/README.md` and the feature files. Fix missing, extra, duplicate or dead entries. Check `features/registry.json` against the files that exist.
3. **Source wave.** One read-only reader per feature, in parallel. Use `brain-kimi` or `brain-muse` for large features (1M-token windows) and `brain-luna` for small ones, or read-only subagents. Each returns: feature summary, source entry points, likely drift with citations, and one live recipe. Readers never drive the app. Consultants are outside services: send source only, never `.env` files, keys, tokens or customer data.
4. **Reconcile.** Merge overlapping recipes into as few app states as practical. Spot-check cited drift. Look at recent commits for user-facing surfaces no feature covers. Name a concrete source path before you call one missing, then add it to the map and the registry.
5. **Live pass.** Required even when the source looks clean. Follow the skill's own Launch, with its test account and seeded data, and take its locks before any shared device. Pause before an action that cannot be undone (a payment, a message to a real person, deleting data the scenario did not create). Hold three rules for the whole pass:
   - Run doctor before the first drive and after any failed drive.
   - Evidence captured so far survives every cleanup; check it at its named location.
   - Nothing a drive started outlives it: clean up after failed attempts too, and release locks.
   A feature that cannot be reached is reported as blocked coverage, never as verified, with the missing prerequisite and the command tried. If the map omits that prerequisite, that is drift.
6. **Triage.** Wrong user-POV description: fix the map. Working behavior the harness cannot drive: fix the harness and drive it again before it ships. Broken app behavior: report it.
7. **Write the lessons.** For every trap the pass hit (a timing wait, a dropped tap, a prompt, persisted state, a data-safety near miss), add one line to that feature's `Gotchas`, or to `SKILL.md` Gotchas when it affects every feature. Do this in the same change.
8. **Ship or stop.** For changed: one change of proven corrections; re-read every changed file first. For clean or blocked: report the outcome and coverage honestly.

## Also do this after ordinary verify runs

Lessons do not wait for the weekly pass. When any verify run hits something the map did not warn about, add it to Gotchas in the change that fixed it.

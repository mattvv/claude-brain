---
name: brain-council
description: Run a review council. Send the same diff, design or decision to three other model families (brain-sol, brain-grok, brain-muse) in parallel, check every finding against the code, fix what holds up, and loop until no real defect remains. Use for a risky diff, a contested design, "council review", "interrogate this", "get a second opinion from other models", or before calling high-stakes work done.
---

# Run a review council

pstack's `interrogate` and `arena` panels, run on claude-brain's consultants. Agreement between families is signal. A lone finding is a lead to check, not a verdict.

## 1. Prepare one prompt

- Save the whole change to a private file: `umask 077; f="$(mktemp "${TMPDIR:-/tmp}/council.XXXXXX")"; git diff "$(git merge-base origin/main HEAD)" > "$f"`. That covers committed, staged and unstaged changes; plain `git diff` misses the first two. Add new files too: `git ls-files -o --exclude-standard | while IFS= read -r n; do git diff --no-index /dev/null "$n"; done >> "$f"`. A design doc works the same way.
- Read the file before it leaves the machine. Remove secrets, tokens, `.env` contents and customer data; consultants are outside services.
- Reviewers attach the file with `brain-ask --context-file` (native applet, the default install; the legacy fallback has no `--context-file`, so paste the text into the prompt there).
- State the intent in two or three sentences, the repo constraints (language versions, platforms, hard rules), and what "done" means.
- Ask for real defects only: `file:line`, a concrete failure scenario (state and steps, then the wrong behavior), and severity. Then test gaps. No style comments.
- Do not include your own conclusions or suspicions. An independent read is the point.

## 2. Pick the panel

Default: `brain-sol` (GPT), `brain-grok` (Grok) and `brain-muse` (Meta Muse), plus your own read. Each must be a different family from the author of the work. Fallbacks follow the routing table: `brain-astra` for hard logic, `brain-kimi` for very large inputs. A vendor that is not linked drops out of the panel; say so, and do not put a second lane from a family already on it. Effort: `xhigh` for subtle logic and concurrency, `high` otherwise.

## 3. Run it in parallel, in the background

Start all three agents in one message with `run_in_background: true`. While they run, poll with `brain consult wait` and tell the user in one line what each consultant is arguing. A consultant that answers `QUESTIONS:` gets the files it asked for and the same prompt once more, but only files inside the change's scope. Never send credentials, `.env` files, keys or unrelated private files, whoever asks.

## 4. Consolidate

Make one table with these columns: finding, which reviewers raised it, verdict, reason. For each finding:

- Read the cited code yourself before you decide.
- **Real:** you can state the failure scenario from the code. Fix it, and add a test that fails without the fix.
- **Not real:** say why in one line (the code path that rules it out).
- **Real but out of scope or very unlikely:** record it as a known limit.

Two or more families raising the same finding is high signal. A finding only one raised needs the code check before you act. You own every consultant's output: never paste their text as your conclusion.

## 5. Loop

After the fixes, run the full test suites, save a new diff, and send it to the panel again with the same prompt. Stop when a round finds no new real defect, or after three rounds; then report what remains. Report each round: findings, verdicts, fixes, and test results.

## Arena mode: choosing between designs

Use this when several designs are viable and the choice matters (a data model, an API shape, a state machine).

1. Write the problem, the constraints, and the axes that decide it (for example correctness risk, migration cost, reader load, runtime cost).
2. Ask each family for one complete design sketch, in parallel. Use `brain-luna` for extra mechanical drafts.
3. Compare the sketches in one table, one column per axis, with evidence for each cell.
4. Pick one, and graft the best parts of the others into it. Say what you rejected and why.
5. Prototype the riskiest part when a quick experiment can settle the choice. Build it in a scratch folder or a throwaway branch, never mixed into uncommitted work, and check `git status` before you delete it after it decides.

# claude-brain consultant visibility

Default: run consultations and `brain-*` bridge agents in the background — but keep
them visible. `brain-ask --stream` tees its live output to
`~/.local/state/brain/consult/current`.

**The user cannot see Bash output.** In a Remote Control session (Claude app /
claude.ai/code) your chat text is the only channel that reaches them. Polling a log
inside a long Bash loop shows them nothing but "running 1 task".

So while a consultation is running:

1. Poll briefly — `sleep 45; brain consult status` — never a loop of sleeps, and
   never more than ~60s in one Bash call.
2. Write one line of chat between polls, saying what the consultant is currently
   arguing, not just how many bytes arrived.
3. Repeat until the completion notification, then relay the full result.

Two hooks enforce this: `consult-poll-guard.sh` rejects Bash calls that block for
minutes while a consult streams, and `consult-progress.sh` pushes a progress line to
the user after each tool call. The hooks guarantee the user sees *something*; only you
can tell them what it means.

Expect a silent window: at `--effort xhigh` the log stays at 0 bytes for several
minutes while the model reasons. Say so explicitly — otherwise it reads as a hang.

In a terminal session the statusline (`host/claude/statusline.sh`) already shows the
live tail; offer `brain consult watch` for the full stream.

Long consultations exceed the 10-minute foreground Bash cap — launch them with
`run_in_background: true`. Consult inline in the main chat (foreground streaming) only
for short calls or when the user asks for it.

(The user can flip this default with: `brain config consult foreground`.)

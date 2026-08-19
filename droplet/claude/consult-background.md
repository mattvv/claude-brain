# claude-brain consultant visibility

Default: run consultations and `brain-*` bridge agents in the background — but keep
them visible. `brain-ask --stream` tees its live output to
`~/.local/state/brain/consult/current`. Pick the channel by where the user is:

- Remote Control session (Claude app / claude.ai/code — no terminal UI): narrate in
  chat. While a consultation runs, poll the consult log (e.g.
  `timeout 55 tail -c +OFFSET -f …/current`) and post short progress lines — bytes so
  far and what section/topic the consultant is currently writing. Never sit silent on
  "running 1 task".
- Terminal session: the user's statusline (droplet/claude/statusline.sh) already shows
  the live tail; offer `tail -f` on the log for the full stream.

Long consultations exceed the 10-minute foreground Bash cap — launch them with
`run_in_background: true`. Relay the full result when the completion notification
arrives. Consult inline in the main chat (foreground streaming) only for short calls
or when the user asks for it.

(The user can flip this default with: `brain config consult foreground`.)

# claude-brain usage-aware routing

Your Claude subscription is metered in rolling windows (a ~5h session window, weekly
windows, and sometimes a weekly window scoped to one model). The other vendors behind the
`brain-*` consultants are separate subscriptions with separate limits — spending one does
not spend the others.

`brain usage` reports the real numbers: per-window utilisation, which window is currently
binding, when it resets, and which consultant vendors are linked and able to take work.

Anthropic and ChatGPT both report genuine headroom, so quote those figures freely. Grok and
Kimi expose no usage endpoint and are shown as *linked, headroom not measurable* — never
invent a number for them. A consultant vendor that is itself at its reserve stops being
offered as a destination, so check `brain usage` before assuming ChatGPT has room.

**As headroom falls, move work off Anthropic rather than slowing down.** The order of
preference in the routing table still applies; what changes is how much you do in-session:

- Plenty of headroom — work normally.
- Low headroom (you will be told, with the live number) — prefer a `brain-*` consultant
  over an Anthropic-backed subagent, and route substantial implementation, review, and
  bulk reading through a consultant instead of doing it yourself. Keep your own turns for
  orchestrating, judging the result, and talking to the user.
- At the reserve — dispatching an Anthropic-backed subagent (`Explore`, `Plan`,
  `general-purpose`, `brain-fable`, …) is blocked by the guard hook. This is deliberate:
  the reserve is what keeps the session able to answer at all. `brain-*` consultants are
  never blocked; they are the way out.

If the guard blocks a dispatch, do not retry it and do not work around it. Either do the
step inline, or hand it to a consultant. Tell the user what happened and mention that
`brain usage override <minutes>` lifts the block if they would rather spend the reserve.

Honest reporting: in the RC lane a `brain-*` agent is a *bridge* — it runs on Claude and
relays to the other model, so offloading saves real tokens but not all of them. In the
multi lane the consultant executes natively and the saving is much larger. Do not claim
more than that.

# claude-brain operations (this is someone's own computer)

You run ON your owner's personal machine (`__HOSTDESC__`) as their user account — not on a
disposable cloud VM. Everything you do here has consequences for a computer they use for
other things. Be useful, but ask before changing the machine itself.

__SCOPE_NOTE__

**Sudo is not free here.** __SUDO_NOTE__ Never try to feed a password to `sudo`. If a
step needs privileges you don't have, stop and tell the user the exact command to run.

**Installing tools**: ask first, then use this machine's package manager
(`__PKG_HINT__`). Language-level installs that stay inside the user's home
(`pipx install`, `npm i -g` with a user prefix, `cargo install`) are lower risk than
system packages — prefer them when there's a choice. MCP servers are fine to add on
request: `claude mcp add <name> -- <command>` (user scope: `claude mcp add -s user ...`);
tell the user it loads on the next session restart.

**Link AI accounts yourself** when the user asks (e.g. "connect my ChatGPT"). Run these
with the Bash tool and relay the URL to the user in chat:
1. `brain auth start <chatgpt|grok|kimi>` — prints a login URL (ChatGPT also prints a
   device code). Show the user the URL (and code) and ask them to open it on any device
   and approve.
2. ChatGPT finishes on its own: poll `brain auth check chatgpt` (every ~15s, up to 2 min).
3. Grok/Kimi: after approving, the user's browser lands on a `localhost` address that
   won't load. Ask them to copy that address and paste it to you, then run
   `brain auth paste <vendor> '<pasted-url>'`.
4. Confirm with `brain auth check <vendor>` and `brain status`.

**Show the user running web apps** with `brain expose` (never by opening firewall ports,
and never by touching this machine's firewall settings):
- Dev server: start the app, run `brain expose <port>`, give them the printed
  `https://...ts.net` link — it works on their phone if it's on their tailnet.
- To share with someone else: `brain expose <port> --public` (Tailscale Funnel —
  world-reachable). Say so plainly, and run `brain expose off` when the demo is over.
- If expose says Tailscale isn't set up, offer to link it with `brain auth tailscale`
  and relay the approval URL.

**Set up repos for phone sessions**: `brain repo add <owner/name>` clones a repo and
starts a Remote Control server for it, so its sessions appear in the Claude app.
`brain repo ls` / `brain repo stop <name>`. If the user already has the repo checked out
somewhere on this machine, ask which copy they want you to work in rather than cloning a
second one.

**Staying reachable**: this computer can sleep, and a laptop that sleeps is not a brain.
If the user says sessions keep dying or vanish after a reboot, check
`brain autostart status` and `brain keepawake status` and offer to fix them —
`brain keepawake` changes a system sleep setting, so let the user confirm it.

**Adjust brain defaults on request**: `brain config` shows the user's settings. If they
ask to watch consultants work live (or to stop watching), run
`brain config consult <foreground|background>`; honor the new choice immediately in the
current session too.

**Update claude-brain yourself**: `brain update` pulls the latest release, refreshes
agents/hooks/routing, and restarts the router. Safe to run mid-session; a new Claude
binary applies on the next session restart.

**Compression (save tokens, both directions)**: a `brain-compress` subsystem compacts
verbose output while keeping the exact original recoverable.
- Shell output is compacted automatically for eligible commands (git log/diff, tests,
  grep, find…) via a hook — you do nothing. Every compacted result starts with
  `[brain-compress id=bc_… lossy=yes]`; get the full original with
  `brain compress show <id> --full` (or `--lines A:B`).
- For a large file, prefer `brain compress read PATH --outline` (signatures),
  `--query '<goal>'` (matching regions), or `--lines A:B` over reading it whole.
- When you consult a `brain-*` model about files, the bridge should pass them with
  `brain-ask --context-file PATH` (or `--context-range PATH@A:B`) rather than pasting
  them, and may add `--response review|debug|architecture|concise` for a terser answer.
- Report usage honestly with `brain compress savings` / `brain compress stats` (three
  separate classes: provider ground-truth, measured bytes, estimated tokens — never a
  single hyped number). Turn it all off with `brain compress off`. Nothing is ever
  silently dropped.

**Never** print or copy the contents of `~/.config/brain/token`,
`~/.config/brain/proxy-config.yaml`, or anything in `~/.cli-proxy-api/` — they are live
credentials for the user's own accounts. Never open firewall ports or change firewall
rules (the router must stay loopback-only). Never delete or rewrite files outside the
work you were asked to do — this is the user's daily-driver machine, and there may be no
backup. `brain status` is your health check.

# claude-brain operations

You run ON the brain droplet as user `brain` (passwordless sudo). The machine is yours to
administer — when the user asks for a capability, set it up yourself rather than giving
them instructions. Report what you did.

**Install tools directly** when a task or the user needs them:
- System packages: `sudo apt-get install -y <pkg>`
- Node/npm tools: install Node first if needed (`sudo apt-get install -y nodejs npm`), then `sudo npm i -g <tool>`
- Python tools: `pipx install <tool>` (install pipx via apt first)
- MCP servers: `claude mcp add <name> -- <command>` (user scope: `claude mcp add -s user ...`).
  Tell the user a new MCP server loads on the next session restart.

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

**Update claude-brain yourself**: `brain update` pulls the latest release, refreshes
agents/hooks/routing, and restarts the router. Safe to run mid-session; a new Claude
binary applies on the next session restart. The `brain` launcher also checks for updates
at startup and prompts.

**Never** print or copy the contents of `~/.config/brain/token`, `~/.config/brain/proxy-config.yaml`,
or anything in `~/.cli-proxy-api/` — they are live credentials. Never open firewall ports
(the router must stay loopback-only). `brain status` is your health check.

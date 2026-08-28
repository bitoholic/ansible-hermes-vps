# 03: MCP servers as data

**What to build:** `mcp_servers` becomes part of each `hermes_profiles` entry (list/mapping) and is rendered into `config.yaml` by the consolidated template (ticket 02), instead of being hard-coded per template file. `coder` declares context7 + github + playwright; `intel` declares none (or a reduced set). Enabling/disabling an MCP server is a one-line data change.

**Blocked by:** 02.

**Status:** ready-for-agent

- [ ] `mcp_servers` lives in the profile entry, not inline in a template.
- [ ] `coder` gets context7/github/playwright with correct env wiring; `intel` gets none.
- [ ] Default profile's mcp_servers (context7/github/playwright) declared as data, matching current `config.yaml.j2`.
- [ ] Render test asserts coder has 3 servers, intel has 0.

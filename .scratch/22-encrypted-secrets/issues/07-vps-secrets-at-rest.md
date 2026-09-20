# 07: Tighten credential-bearing files on the VPS to least privilege (droppable)

**What to build:** Rendered files on the VPS that contain credentials are readable only by whoever actually needs them, while the admin user can still run `docker compose` as today. The live audit found the rendered compose file, the gateway Caddyfile and the Matrix homeserver config readable by every local account. **Droppable:** removing this ticket affects no other ticket.

**Blocked by:** None (can start immediately)
**Blocks:** None

**Status:** ready-for-agent

- [ ] An audit lists every rendered file that contains credentials, who actually reads it (an operator, the docker group, a specific container user), and the chosen owner and mode
- [ ] The compose file is readable by root and the docker group only, so the admin user's `docker compose` usage keeps working
- [ ] Files read only by a container are restricted to the user or root that container runs as
- [ ] Render-level assertions pin the owners and modes
- [ ] No container fails to start because of the change (verified at render level; the attended check happens at the next real deploy and is noted here)

## Notes

See epic 22 spec, "Implementation Decisions" (secrets at rest on the VPS). Included by author decision — the operator may drop it.

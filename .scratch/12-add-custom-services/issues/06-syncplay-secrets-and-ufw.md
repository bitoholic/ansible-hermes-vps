# Ticket #06: Syncplay secrets and UFW IP allowlist

**Blocked by:** #04
**Blocks:** #07

## Description

Add Syncplay secrets to the manifest and UFW rules for IP-restricted access.

1. **Secrets manifest** (`group_vars/all/secrets.yml`):
   ```yaml
   syncplay_password:
     env: SYNCPLAY_PASSWORD
     required: true
   ```

2. **Syncplay allowed IPs** (`group_vars/all/main.yml`):
   ```yaml
   syncplay_allowed_ips:
     # Friends' home IPs or ranges — add one entry per friend
     # Format: CIDR notation (e.g., "203.0.113.0/24" or "198.51.100.42/32")
   ```

3. **UFW IP allowlist** in `roles/tailscale/tasks/main.yml`:
   - For each IP in `syncplay_allowed_ips`: `ufw allow from <IP> to any port 8999 proto tcp comment "Syncplay friend access"`
   - Also: `ufw limit 8999/tcp comment "Syncplay rate limit"` — rate-limits all traffic on the port (brute-force protection)

## Acceptance criteria

- `secrets.yml` has `syncplay_password` entry
- `main.yml` defines `syncplay_allowed_ips` list (empty or populated)
- UFW has `allow from <IP> to any port 8999` for each allowed IP
- UFW has `limit 8999/tcp` for rate-limiting
- If `syncplay_allowed_ips` is empty, port 8999 has only rate-limit (effectively closed)
- `ansible-playbook --syntax-check` passes

## Notes

- The `community.general.ufw` module is used (same as existing tailscale role tasks).
- `syncplay_allowed_ips` is a list of CIDR ranges or individual IPs.
- Friends with dynamic IPs can use their home router's public IP.
- UFW is the single firewall owner (tailscale role). No new UFW roles or tasks.
- This creates an "IP-restricted public access" access model — distinct from Tailscale-only and fully public.
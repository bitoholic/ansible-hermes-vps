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
     - "192.168.x.y"  # Friend's home IP (placeholder, update before run)
   ```

3. **UFW IP allowlist** in `roles/tailscale/tasks/main.yml`:
   - For each IP in `syncplay_allowed_ips`:
     ```yaml
     - name: Allow Syncplay from friend IPs
       community.general.ufw:
         rule: allow
         direction: incoming
         from: "{{ item }}"
         port: 8999
         proto: tcp
         comment: "Syncplay friend access"
       loop: "{{ syncplay_allowed_ips }}"
     ```
   - Rate-limit all traffic on port 8999:
     ```yaml
     - name: Rate-limit Syncplay
       community.general.ufw:
         rule: limit
         port: 8999
         proto: tcp
         comment: "Syncplay rate limit"
     ```

## Acceptance criteria

- `secrets.yml` has `syncplay_password` entry
- `main.yml` defines `syncplay_allowed_ips` list (starting with one example entry)
- UFW has `allow from <IP> to any port 8999` for each allowed IP
- UFW has `limit 8999/tcp` for rate-limiting
- If `syncplay_allowed_ips` is empty, port 8999 has only rate-limit (effectively blocked)
- `ansible-playbook --syntax-check` passes

## Notes

- The `community.general.ufw` module is used (same as existing tailscale role tasks).
- `syncplay_allowed_ips` is a list of CIDR ranges or individual IPs.
- Friends with dynamic IPs update their home router and provide the new IP.
- This creates an "IP-restricted public access" access model — distinct from Tailscale-only and fully public.
- UFW is the single firewall owner (tailscale role).
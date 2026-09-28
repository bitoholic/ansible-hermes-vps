# 🏠 Hermes VPS

This repository provisions a personal "second brain" + agent stack on a bare Ubuntu/Debian VPS using modular Ansible roles and Docker Compose. Secrets live **encrypted, in this repository** (SOPS + age) and are decrypted only into the deploy wrapper's child process — never to disk, never sourced into a shell. See [Local Secrets Workflow](#-local-secrets-workflow) and [ADR-0007](docs/adr/0007-sops-age-encrypted-secrets.md).

> ⚠️ **Status: pre-production.** This stack has known security and reliability gaps — see [Known Limitations](#-known-limitations--open-issues) before you put real credentials or sensitive wiki content on it.

## 🏗️ Architecture at a Glance

| Role | Purpose |
|---|---|
| `users` | Creates the dedicated `llm_wiki` system user/group that owns all persistent data |
| `ssh_hardening` | Disables password auth, disables root login, deploys `AllowUsers` |
| `common` | Installs base hardening packages, enables unattended-upgrades, configures UFW |
| `tailscale` | Installs Tailscale and owns the host perimeter: UFW rules and the `DOCKER-USER` chain that enforces the published-port classes (public / tailnet-only / Syncplay allowlist). The chain is loaded atomically from one rendering, by the same loader at deploy time and by a boot firewall unit (see [Firewall persistence](#-firewall-persistence-across-reboots)) |
| `docker` | Installs Docker Engine + Compose plugin, owns the consolidated `docker-compose.yml` at `/opt/hermes-vps`, and brings up the full stack (Caddy, Authelia, SilverBullet, Conduit, signal-cli, hermes-agent) on the `gateway` and `internal` networks |
| `authelia` + `silverbullet` | Caddy reverse proxy → Authelia (MFA forward-auth) → SilverBullet wiki, bound to `127.0.0.1` |
| `gateway` | The single writer of the ingress Caddyfile; renders one site block per entry in `gateway_routes` (`group_vars/all/gateway.yml`), wrapping each in the shared `mfa_auth` snippet unless `mfa: false`. |
| `hermes` | Builds and runs the single `hermes-agent` container (see below) |
| `backup` | Real-time wiki→GitHub sync on file change, plus a nightly PR creation cron job |

### 🧩 Hermes agent (second brain)

There is **one** `hermes-agent` container, built from the local `Dockerfile` and running a single "second brain" agent (the `default` profile) mounted at `/opt/data`:

- **Second brain** (default profile) — chief-of-staff persona that also codes, researches, and gatekeeps the Markdown wiki at `/opt/data/wiki`, reachable over Signal. Heavy or parallel work is delegated to anonymous `delegate_task` subagents (each gets its own git worktree via `worktree_isolation`), so there is no need for separate Coder/Intel profiles.

The agent is defined entirely as **data** in `group_vars/all/main.yml` → `hermes_profiles` (a single `default` entry). Model, `tools`, `mcp_servers`, skill auto-load, and capability scoping live in that one entry, and the `hermes` role renders it through a single template loop. (True filesystem sandbox isolation between delegated subagents is provided by git worktree isolation; they share the container filesystem otherwise — see the gap noted below.)

Messaging is handled by a standalone `signal-cli-api` REST container on an internal Docker network only (no published port), restricted to your personal number via `SIGNAL_ALLOWED_USERS`. Voice mode (Whisper STT, NeuTTS/Piper TTS) runs fully offline inside the same container via the `ffmpeg`/`hermes-agent[voice]` Dockerfile layer.

### 🐳 Consolidated Docker Compose Stack

All Docker services are managed by a **single** `docker-compose.yml` at `/opt/hermes-vps/docker-compose.yml`, rendered by the `docker` role. The stack is composed of service fragments in `roles/docker/templates/services/`, each declaring its image, volumes, networks, and dependencies:

- **`caddy`** — Reverse proxy on the `gateway` network; terminates TLS, proxies to backends, and runs Authelia forward-auth for public routes.
- **`authelia`** — MFA provider on the `gateway` network; challenges non-Tailscale clients.
- **`silverbullet`** — Markdown wiki on the `gateway` network, published on port 3000.
- **`conduit`** — Personal Matrix homeserver on the `internal` network; reachable by Hermes over the shared internal network, and by Matrix clients at `https://matrix.<domain>:8443` (real ACME cert via Cloudflare DNS-01, registration token required — ADR-0003, superseded in part by ADR-0004's port/cert-issuance move).
- **`signal-cli`** — Standalone Signal REST API on the `internal` network (no published port).
- **`hermes-agent`** — The single agent container on the `internal` network, depends on `signal-cli`.

The `docker` role owns the consolidated compose file and brings up the full stack via `docker compose up -d`. Each service role (conduit, silverbullet, hermes) reduces to: create directories/volumes with ownership, render config files, and write service fragments.

## 🔐 Local Secrets Workflow

Every credential this playbook needs lives **encrypted** in `secrets/secrets.enc.env` (SOPS, age
recipients), committed alongside the code. There is no plaintext `.env` in this workflow — the deploy
wrapper decrypts the store directly into its child process's environment and nothing else ever touches
disk in plaintext. `setup-env.sh` (the old interactive prompt script) now only redirects to the tools
below, which replace its behavior entirely. Full detail, including onboarding a new workstation and incident response, is in
[`docs/secrets-runbooks.md`](docs/secrets-runbooks.md).

### 1️⃣ First-time setup on a workstation

Requires `sops` and `age` on `PATH` (per-OS install commands: [`docs/secrets-runbooks.md`](docs/secrets-runbooks.md#onboarding-a-workstation)).

```bash
scripts/secrets init-key                    # creates ~/.config/sops/age/keys.txt, prints ONLY the public key
scripts/secrets add-recipient <public-key>  # an existing workstation runs this to admit a new one
```

The very first workstation additionally generates an offline **break-glass** key
(`scripts/secrets init-key /path/on/removable/media`) and adds its public key as a second recipient, so
losing every workstation doesn't lock the operator out. See the runbooks doc for the full onboarding and
break-glass procedures.

### 2️⃣ Maintain the store

```bash
scripts/secrets check     # names missing or undeclared, by name only — never a value
scripts/secrets fill      # guided, hidden-input fill of missing required values
scripts/secrets edit      # edit the store in $EDITOR (decrypted only in memory)
scripts/secrets rotate    # generate a new data encryption key, same recipients
```

None of these ever print a decrypted value or write plaintext to disk (`edit`'s temporary file lives on
a tmpfs and is removed whether the editor exits cleanly or not).

### 3️⃣ Run Ansible against the VPS

`scripts/deploy` is the **only** supported way to run this repository's playbook — it decrypts the
store into the child process's environment only, runs `site.yml`, and streams the output live through a
redactor that masks every decrypted value:

```bash
scripts/deploy
```

### 4️⃣ Preview changes before applying

```bash
scripts/deploy --check --diff
```

### 5️⃣ Selective role skipping (fast redeploys)

The wrapper passes a fixed, vetted set of flags through to Ansible, including `--skip-tags`:

```bash
# Skip slow roles when only updating hermes configuration
scripts/deploy --skip-tags hermes,backup

# Minimal API deployment: skip everything except conduit and hermes
scripts/deploy --skip-tags tailscale,docker,authelia,gateway,silverbullet,backup

# Full deploy (default, no skips)
scripts/deploy
```

Protected roles that **cannot** be skipped: `secrets`, `users`, `ssh_hardening`, `common`.
Skippable roles: `tailscale`, `docker`, `conduit`, `hermes`, `authelia`, `gateway`, `silverbullet`, `owntracks`, `backup`, `beszel`, `adguard`, `exit_nodes`.

`scripts/deploy` refuses anything outside this fixed flag set — extra variables, ad-hoc modules, other
playbooks or inventories, and foreign connections — since it hands the decrypted store to whatever it
runs; see [ADR-0007](docs/adr/0007-sops-age-encrypted-secrets.md) for why.

### Adding a new secret (for a future epic)

1. Add one entry to `secrets_manifest` in `group_vars/all/secrets.yml` (`env:`, `required:`, optional
   `default:`) — or, if it's not a value the `secrets` resolver injects (rare), add it to the
   `EXTRA` list in `scripts/generate-env.py` instead (the name-set rule's *declared extras*: every
   name the store may hold is either a manifest name or a declared extra, and this is the one place
   extras are listed).
2. Regenerate the names-only reference: `python3 scripts/generate-env.py` (updates `.env.template`,
   which lists every variable name Ansible reads — never a value — and is checked for drift by
   `tests/lint.sh`).
3. Add the actual value to the store: `scripts/secrets fill` (prompts for whatever's newly missing) or
   `scripts/secrets edit`.

## 🧭 Manual Post-Deploy Steps

A few services need a one-time step the operator completes by hand — either because the credential is generated by a system this playbook just deployed (so Ansible can't originate it ahead of time), or because it's a setting in another provider's own console outside this repo's reach.

- **Beszel agent pairing** (epic 18): after the first deploy brings up the `beszel-hub` container, visit its dashboard (`monitor.<domain>` over Tailscale, or `<tailscale-ip>:8090` directly) and add the local VPS as a "system." That generates a key/token pair — add them to the store with `scripts/secrets edit` (or `fill`) as `BESZEL_AGENT_KEY`/`BESZEL_AGENT_TOKEN`, then redeploy so the agent container picks them up. Until this is done, the agent container will fail to authenticate against the hub — a self-contained failure of that one container, not a block on anything else.
- **AdGuard as the tailnet's DNS resolver** (epic 18): AdGuard Home is deployed and already serving DNS on port 53 (Tailscale-only) once the playbook finishes, but nothing points your devices at it yet. In the [Tailscale admin console](https://login.tailscale.com/admin/dns), under DNS settings, add the VPS's Tailscale IP as a **global override nameserver** — not split DNS, which solves a different problem (routing specific domains elsewhere) and won't give you network-wide ad-blocking. Once set, every tailnet device's DNS traffic routes through AdGuard.
- **Matrix/OwnTracks DNS-01 cert verification, then client reconfiguration** (epic 19 #02): after this deploy, and *before* flipping either host's Cloudflare DNS record to proxied, confirm Caddy actually obtained a real DNS-01 cert on the new `:8443` listener:
  ```bash
  docker compose -f /opt/hermes-vps/docker-compose.yml logs caddy | grep -i "certificate obtained successfully"
  ```
  should show a line for both `matrix.<domain>` and `owntracks.<domain>`. Then confirm the served cert itself is real (not the internal CA's self-signed one):
  ```bash
  openssl s_client -connect <vps-ip>:8443 -servername matrix.<domain> </dev/null 2>/dev/null | openssl x509 -noout -issuer
  ```
  should print a Let's Encrypt issuer. Once both check out, update the Matrix client's homeserver URL and the OwnTracks app's recorder URL on each device from `:8448` to `:8443` — a one-time manual per-device change; Ansible cannot push client-side app settings.

## 🧪 Local Testing

```bash
./tests/lint.sh
```

or a local dry-run against `localhost`:

```bash
ansible-playbook -i localhost, tests/test_playbook.yml --check --diff
```

## ⚠️ Known Limitations / Open Issues

Tracked from the last infrastructure audit. Don't consider this deploy-ready until these are resolved:

- [ ] **Delegated subagents share the container filesystem.** The single `hermes-agent` container mounts `hermes_home:/opt/data`; `delegate_task` children get isolated git worktrees (`worktree_isolation: true`) but otherwise share the same bind mount, so a child can read the wiki and the agent's `.env`. Filesystem sandboxing per child is out of scope.
- [x] ~~The GitHub token was embedded directly in the wiki's git remote URL (persists in `.git/config` in plaintext).~~ Closed: the clone now uses a token-less URL and git authenticates via a credential helper / askpass that reads `GITHUB_TOKEN` from the environment (see `roles/backup/files/git-credential-env`). The token value is never written to `.git/config` or any remote URL.

## 🔒 Firewall persistence across reboots

Docker-published ports bypass UFW, so who may reach them is decided by rules in the `DOCKER-USER` chain. Kernel rules are lost at reboot, so (epic 21) the `tailscale` role installs a **boot firewall unit** (`hermes-docker-user-firewall.service`) that loads those rules *before* Docker starts and again on every Docker (re)start. Docker preserves a pre-existing chain, so by design there is no window in which a published port is live without its rule (measured in the spike; verified on real systemd by the attended drill). Deploys load the very same rendering through the same loader, atomically, and heal a chain that was emptied behind their back (a reboot) even when no file changed.

- **Change a port class** in `group_vars/all/main.yml` (`docker_published_public_ports`, `docker_published_restricted_ports`, `docker_published_restricted_udp_ports`, `syncplay_allowed_ips`) — one edit, both IP families.
- **Fail-closed coupling (staged):** `tailscale_docker_user_firewall_fail_closed` (default `false`) makes `docker.service` *require* the boot unit so Docker does not start if the rules could not be loaded. It ships disabled (no drop-in is installed) and is enabled by the attended reboot drill once the unit has been observed working. What is *always* live is the unit's own wiring — `Before=`, `PartOf=` and `WantedBy=docker.service` (a `docker.service.wants` link) — so a Docker start pulls the unit in and a Docker restart re-runs the loader; that is not a hard dependency.
- **`--skip-tags tailscale`** skips *updating* the rules and unit; it never removes an already-installed unit, so a provisioned host stays protected.
- The unit and loader touch only the `DOCKER-USER` chain — never UFW, the INPUT chain or sshd.
- **To reload the rules by hand** run `sudo /usr/local/sbin/hermes-docker-user-rules apply` (atomic and idempotent) — or just deploy. Do **not** `systemctl restart hermes-docker-user-firewall`: with the fail-closed coupling on, `docker.service` requires that unit, so restarting it restarts Docker and every container.

## 📝 Notes

- Pre-flight `assert` tasks stop the playbook early if core secrets are missing.
- UFW is applied in a lockout-safe order: SSH key is authorized first, hardened `sshd` config is deployed, *then* UFW is enabled.
- SilverBullet is bound to `127.0.0.1` so Docker never exposes it directly — all public traffic goes through Caddy → Authelia.

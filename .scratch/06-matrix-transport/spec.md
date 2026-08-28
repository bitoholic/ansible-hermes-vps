# Spec: Matrix transport (personal Conduit homeserver)

> Status: ready-for-agent
> Source: Operator request to add a second IM transport to Hermes alongside Signal
> Related: `07-tailscale-private-access` (Conduit is reached over Tailscale), `CONTEXT.md` (IM transport, Matrix homeserver, Hermes bot user, personal homeserver)
> Vocabulary: see `CONTEXT.md`.

## Problem Statement

The operator talks to Hermes today only over Signal. They want a **second IM transport** — Matrix — so they can use a normal Matrix client (e.g. Element) to DM the agent. The agent (`nousresearch/hermes-agent`) natively supports Matrix (it is itself a Matrix client via the `mautrix` SDK), so no external bridge is needed. The operator wants a **personal Conduit homeserver** (private, non-federated) that hosts both their own account and the Hermes bot account, rather than relying on a public Matrix server.

## Solution

Add a new `conduit` role that runs a private Conduit homeserver on the internal Docker network, and wire Hermes to it by extending the `hermes` role with `MATRIX_*` environment (default profile only, mirroring the existing Signal wiring). Conduit is reached only over the Tailscale VPN (see epic `07-tailscale-private-access`) — it is **not** published to the public internet. The Hermes bot account (`@hermes:<homeserver>`) is provisioned automatically via Conduit's registration shared secret; Hermes logs in with `MATRIX_USER_ID` + `MATRIX_PASSWORD` (no cross-role token-file plumbing). E2EE is enabled for the DMs.

## User Stories

1. As an operator, I want a private Matrix homeserver on my VPS, so that I control my own Matrix data and don't depend on a public server.
2. As an operator, I want Conduit to be non-federated and not publicly registered, so that only I (and the Hermes bot) can have accounts on it.
3. As an operator, I want to register my own Matrix account (`@jacek:<homeserver>`) from Element, so that I can log in with a normal client.
4. As an operator, I want the Hermes bot account (`@hermes:<homeserver>`) to exist automatically after provisioning, so that I don't manually create it.
5. As an operator, I want to DM `@hermes` from Element and get replies, so that Matrix is a working IM transport to Hermes.
6. As an operator, I want E2EE enabled on the Matrix DMs, so that my conversations with Hermes are private at rest and in transit.
7. As a developer, I want Hermes to receive Matrix messages without an extra bridge container, so that the transport is just env wiring (the agent is already a Matrix client).
8. As a developer, I want the `MATRIX_*` env vars wired like the `SIGNAL_*` ones (in `env_default.j2`), so the two transports follow the same pattern.
9. As a developer, I want Matrix wired to the default (Jack-O-Rama) profile only for now, so it matches today's Signal scope and can extend to sub-profiles later.
10. As an operator, I want Conduit reachable only over Tailscale, so the homeserver is not exposed on the public internet.
11. As a reviewer, I want `conduit` to be a single-seam role that owns the homeserver (container, data dir, registration config), so "who owns Matrix?" has one answer.
12. As an operator, I want the bot account provisioning to be idempotent, so re-running the playbook doesn't create duplicate accounts or fail.
13. As a developer, I want the Conduit registration shared secret and the bot password sourced from `secrets`, so no credential is hard-coded.
14. As an operator, I want the Conduit data dir backed up with the rest of the stack eventually, so I don't lose rooms/keys (see Out of Scope for v1 stance).

## Implementation Decisions

- **New `conduit` role** — the sole owner of the Matrix homeserver: deploys the Conduit image, creates its data dir (under the existing wiki-store ownership convention where applicable), and renders the Conduit config with a **registration shared secret** and `allow_registration` enabled (personal use). It attaches to the internal Docker network so `hermes-agent` can reach it; it does **not** publish a Matrix port to the host (Tailscale is the access path).
- **Bot provisioning**: a task in the `conduit` role calls Conduit's registration endpoint using the shared secret to ensure `@hermes:<homeserver>` exists with a password taken from `secrets`. Idempotent (skip if the user already exists). Hermes then authenticates with `MATRIX_USER_ID` + `MATRIX_PASSWORD` — avoiding any access-token file passed across roles.
- **`hermes` role consumes `conduit`**: `meta/main.yml` gains `depends_on: conduit`. `env_default.j2` gains `MATRIX_HOMESERVER` (the Conduit container URL, e.g. `http://conduit:8008`), `MATRIX_USER_ID`, `MATRIX_PASSWORD`, `MATRIX_ALLOWED_USERS`, `MATRIX_ALLOWED_ROOMS`, and E2EE enabled. Default profile only, mirroring the Signal block.
- **Secrets**: `secrets.conduit_registration_secret`, `secrets.matrix_bot_password`, `secrets.matrix_allowed_users` (and room restrictions) are added to the secret manifest / `group_vars/all/secrets.yml`, following the epic-01 single-seam contract (read from env, never hard-coded).
- **No bridge**: the agent's native Matrix support means no `mautrix`/`hookshot`/appservice container is added.
- **Network**: Conduit joins the same internal network as `hermes-agent` (e.g. `hermes_net`); the operator reaches it over Tailscale (epic `07`). No public Matrix listener.

## Testing Decisions

- **What makes a good test**: assert external behavior — after `conduit` runs, the homeserver container is up, the registration endpoint accepts the shared secret, and `@hermes` exists; after `hermes` runs, `env_default.j2` renders with the `MATRIX_*` vars. Do not assert on container internals.
- **Modules tested**: `conduit` (idempotent bot provisioning, config renders) and `hermes` (env renders `MATRIX_*`, dependency ordering). Prior art: the repo's existing `--check --diff` dry-run and top-level `assert` pre-flight pattern (epic 04/05) — assert the new `secrets.*` are defined before applying.
- **Operator validation**: a live `ansible-playbook --check --diff` and a manual Element↔`@hermes` DM are validated on the VPS (needs the Conduit container + Tailscale, which CI lacks).

## Out of Scope

- **Conduit data backup**: v1 does not add Conduit DB backup to the `backup` role (deferred). Note: the bot's E2EE keys live in the agent's `/opt/data`, already covered by the wiki backup's data dir, so keys survive regardless.
- **Publishing Conduit publicly** (with or without MFA). It is intentionally Tailscale-only.
- **Other transports** (Telegram/Discord/Slack/WhatsApp) and **sub-profile Matrix** (coder/intel) — future work.
- Changes to the agent binary or its transport code (closed-source upstream).

## Further Notes

- The agent natively supports Matrix via `mautrix` (`gateway/platforms/matrix.py` upstream); this repo only feeds env vars, exactly like Signal. Confirm the exact `MATRIX_*` names against the agent's current env reference when implementing (they have shifted between `MATRIX_ENCRYPTION` and `MATRIX_E2EE_MODE`).
- Conduit image/version is a deployment detail; pin a specific tag for reproducibility.

## Tickets

Vertical slices under `.scratch/06-matrix-transport/issues/` (blockers-first):

- **#01** `01-scaffold-conduit-role.md` — new `conduit` role: Conduit container, data dir, config with registration shared secret + `allow_registration`, internal network only, no published Matrix port. Depends on `docker`.
- **#02** `02-provision-hermes-bot-account.md` — task provisions `@hermes` via the shared secret + password from `secrets`; idempotent. *Blocked by #01.*
- **#03** `03-hermes-consume-conduit.md` — `hermes` `depends_on: conduit`; `MATRIX_*` env in `env_default.j2` (default profile); secrets added to manifest. *Blocked by #01.*
- **#04** `04-tests-lint-wiring.md` — `tests/check-conduit.sh` (container config, bot idempotency, no published port, Hermes env, gateway unchanged) + pre-flight secret asserts, wired into `lint.sh`. *Blocked by #01–#03.*

---
title: Scaffold conduit role (private Matrix homeserver)
status: ready-for-agent
blocked_by: []
depends_on: [docker]
---

# #01 — Scaffold `conduit` role (private Matrix homeserver)

New role that owns the personal Conduit homeserver end-to-end: deploys the Conduit image, creates
its data dir, and renders the Conduit config with a **registration shared secret** (from `secrets`)
and `allow_registration` enabled (personal, non-federated). It attaches to the internal Docker
network shared with `hermes-agent` and does **not** publish a Matrix port to the host — Tailscale
is the access path (epic `07`).

## What to build

- `roles/conduit/tasks/main.yml`: deploy the pinned Conduit image; create the data dir (under the
  existing wiki-store ownership convention where applicable); render the Conduit config with
  `secrets.conduit_registration_secret` and `allow_registration: true`. Do not publish 8008/8448.
- Attach the container to the same internal network `hermes-agent` uses (reuse `hermes_net`; promote
  it to an external network if cross-compose attachment requires it).
- `roles/conduit/meta/main.yml`: `dependencies: [docker]` so the network exists first.

## Acceptance (Definition of Done)

- [ ] `conduit` container runs; config renders with the shared secret; `allow_registration` on; non-federated.
- [ ] No Matrix port published to the host (Tailscale is the only access path).
- [ ] On the internal network, `hermes-agent` can reach the homeserver URL.
- [ ] Idempotent re-run (`changed=false` on the second apply).

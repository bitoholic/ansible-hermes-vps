# ADR-0002: Consolidated Docker Compose Stack

## Status
Proposed

## Context
Originally, the VPS deployed services using separate `docker-compose.yml` files managed by individual roles (`hermes`, `conduit`, `silverbullet`). This led to:
1.  **Network isolation issues**: Services on different Compose projects cannot easily share internal networks without defining them as `external`, which is manual and error-prone.
2.  **Management overhead**: Stopping or restarting the entire stack required multiple commands.
3.  **Ambiguous state**: It was hard to see the total resource usage and service dependencies across the VPS.

## Decision
We will consolidate all Docker services into a single Compose project managed by a new `docker` role. 

1.  **Fragmented definitions**: Individual roles will still "own" their service logic by providing a **Service Fragment** template.
2.  **Centralized Aggregation**: The `docker` role will collect these fragments and render them into a single `/opt/hermes-vps/docker-compose.yml`.
3.  **Standard Networks**: We will define two primary networks: `gateway` (ingress from Caddy) and `internal` (service-to-service).
4.  **Flat Namespace**: Service and container names will remain flat and descriptive (e.g., `caddy`, `conduit`) to keep them user-friendly.

## Consequences
- **Easier Troubleshooting**: `docker compose ps` and `docker compose logs` now show the entire system state.
- **Improved Connectivity**: Caddy can now reach any backend simply by being on the same `gateway` network.
- **Role Dependency**: Roles like `hermes` or `conduit` no longer manage their own `docker-compose.yml` file; they depend on the `docker` role to render the final stack.
- **Single Point of Failure**: A syntax error in one fragment can prevent the entire stack from starting. We must use `docker compose config` validation.

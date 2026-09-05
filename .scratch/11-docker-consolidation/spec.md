# Spec: Consolidated Docker Role

## Problem Statement
The VPS currently manages Docker services through multiple, disconnected `docker-compose.yml` files scattered across different roles (`hermes`, `conduit`, `silverbullet`). This makes network management difficult, leads to isolation issues (e.g., Caddy cannot reach Conduit because they are on different networks), and makes it hard to add non-Hermes services in a clean, unified way.

## Solution
Implement a centralized `docker` role that consolidates all service definitions into a single managed `docker-compose.yml` file. This role will define a standard set of Docker networks (`gateway`, `internal`) and provide a unified way to attach services to them. It will allow adding new services (including non-AI services) easily through a modular configuration pattern while maintaining a single, easy-to-inspect stack.

## User Stories
1. As a VPS operator, I want all Docker services to be defined in a single location, so I can easily see the state of the entire stack.
2. As a VPS operator, I want standard networks like `gateway` and `internal` defined once, so I can reliably connect services without manually creating networks.
3. As a developer, I want to add a new service (like a database or web app) simply by adding a configuration fragment, so the system is extensible.
4. As a VPS operator, I want to fix the connectivity issue between Caddy and Conduit by placing them on the same `gateway` network, so ingress works correctly.
5. As an operator, I want to control which services are exposed to the public via Caddy vs which remain internal-only, so the security posture is clear.
6. As a VPS operator, I want to avoid name collisions and port conflicts by managing all services in one Compose project.

## Implementation Decisions
- **Consolidation:** Create `roles/docker` which owns a single `docker-compose.yml.j2` template.
- **Service Fragments:** The `docker` role will iterate over a list of service configurations (e.g., `docker_services`) to render the `services` section of the compose file.
- **Network Topology:** 
    - `gateway`: Internal bridge network for Caddy to proxy to backends.
    - `internal`: Internal bridge network for backend-to-backend communication (e.g. Hermes to Conduit).
- **Port Management:** Only Caddy should bind to host ports 80 and 443. Other services should use the `gateway` network unless specific host-port access is required (e.g., Tailscale).
- **Environment Variables:** Standardize the storage and naming of service-specific environment variables.

## Testing Decisions
- **Surface Area:** Test that a single `docker-compose.yml` is rendered with all enabled services.
- **Network Check:** Test that the Caddy container can resolve and reach backend containers (e.g., `conduit`) on the `gateway` network.
- **Validation:** Use `docker-compose config` to validate the syntax of the consolidated file.

## Out of Scope
- Migrating data volumes (volumes should stay in their current locations to avoid disruptive data moves).
- Setting up a container orchestrator (like Swarm or K8s).

## Implementation Notes
- **Ticket 01**: Expanded the `docker` role to own a `docker-compose.yml.j2` template that iterates over `docker_enabled_services` and includes each service fragment from `roles/docker/templates/services/<name>.yml.j2`. Networks (`gateway`, `internal`) and named volumes (`caddy_data`, `caddy_config`) are data-driven via `docker_networks` and `docker_volumes`.
- **Ticket 02**: Caddy fragment added to `roles/docker/templates/services/caddy.yml.j2`; the Caddyfile is rendered to `{{ docker_compose_dir }}/Caddyfile` by the `gateway` role, which now points `gateway_caddyfile_dir` at `{{ docker_compose_dir }}`.
- **Ticket 03**: Conduit migrated to a service fragment; the per-role `docker-compose.yml.j2` was removed and the `docker_compose_v2` start task moved to the `docker` role. Bot provisioning (Conduit registration) remains in the `conduit` role.
- **Ticket 04**: SilverBullet + Authelia migrated to service fragments; the per-role `docker-compose.yml.j2` was removed.
- **Ticket 05**: Hermes agent + signal-cli consolidated into service fragments; `project_name` consistency fixed (`"hermes-agent"` → `"{{ docker_project_name }}"`).
- **Ticket 06**: Added `tests/test_docker_compose.yml` and `tests/check-docker-compose-render.sh` to validate consolidated compose rendering; lint pipeline updated.
- **Ticket 07**: All per-role `docker-compose.yml.j2` templates and `docker_compose_v2` start tasks removed. The `docker` role now owns the single `docker_compose_v2` start task. Each service role reduces to directory/config/fragment tasks only.

## Triage
- ready-for-agent

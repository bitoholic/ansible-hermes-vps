# 06: Update tests to validate consolidated compose rendering

**What to build:** Replace the old per-role Compose tests with a single test that validates
the consolidated `docker-compose.yml` render. The existing `tests/test_gateway_render.yml`
and `tests/test_config_render.yml` stay unchanged (they validate Caddyfile and Hermes config
templates, which are not part of the consolidation). The new test verifies the docker role's
`docker-compose.yml.j2` template renders all enabled services correctly and passes
`docker compose config`.

End-to-end behavior delivered:
- `ansible-playbook tests/test_docker_compose.yml` renders the consolidated compose file
  with all services present and validates its syntax.
- The test uses the same `ansible.cfg` (become=false) and stubs the same env vars as the
  other render tests.
- The test fails if a service fragment is missing or malformed.

**Blocked by:** 05 (all service fragments exist; only the render test remains).

**Status:** ready-for-agent

- [ ] `tests/test_docker_compose.yml` created; renders `roles/docker/templates/docker-compose.yml.j2`
  to a temp dir and asserts each service in `docker_enabled_services` is present.
- [ ] Test passes with stub env vars; fails if a fragment is missing.
- [ ] `lint.sh` updated to run the new test in place of the old per-role Compose tests.
- [ ] `ansible-lint tests/test_docker_compose.yml` passes.
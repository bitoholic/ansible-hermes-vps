# 03: Restart policies for every service, with a guard over the rendered services

**What to build:** The public front door (`caddy`, `authelia`, `silverbullet`) comes back by itself after a reboot or crash, and it becomes impossible to add a service without deciding its restart behavior: every *rendered* service declares a restart policy, and a guard in the standard test run fails if one doesn't. The guard inspects the rendered service set rather than the fragment files, so list-driven fragments (such as epic 23's exit-node pairs, which render several services from one fragment) are covered.

**Blocked by:** None (can start immediately)
**Blocks:** #05, Epic 23 #03

**Status:** done

- [x] `caddy`, `authelia` and `silverbullet` declare a restart policy of `unless-stopped`
- [x] The guard asserts over the **rendered** compose services that every one declares a restart policy; there is no exemption list (a service that genuinely must not restart is added to the guard with a written reason when it first appears)
- [x] The guard fails when a rendered service omits a policy — demonstrated by a negative case, including a case where a single fragment renders more than one service
- [x] The consolidated compose still validates and every existing render test passes unchanged
- [x] The guard runs as part of the standard test run

## Notes

See epic 21 spec, "Implementation Decisions" (restart policies). Epic 23 depends on this guard.

## Implementation notes

- `caddy`, `authelia` and `silverbullet` now declare `restart: unless-stopped` (found live: after the last reboot they stayed down until a manual deploy).
- **The guard inspects the *rendered* service set, not the fragment files** (`tests/support/assert_restart_policies.py`, run over the rendered compose inside `tests/test_docker_compose.yml`), so a list-driven fragment that renders several services from one template — epic 23's exit-node pairs — is checked service by service. There is no exemption list.
- **`restart: "no"` fails, and so does `on-failure[:N]`.** `on-failure` restarts a container only after a non-zero exit; a container the host's shutdown stops cleanly is not reliably restarted by it after a reboot (a review finding), so only `always` and `unless-stopped` count.
- `tests/check-restart-policies.sh` proves the guard has teeth with synthetic rendered files — missing policy, `no`, `on-failure`, a **multi-service fragment with one gap** (the case epic 23 depends on), and an empty render all fail; a fully covered file passes — and pins the three fragments. It is wired into `tests/lint.sh`. Also mutation-checked against the *real* render: removing one fragment's policy fails `tests/test_docker_compose.yml` naming that service.

**Review (round 1): PASS, nothing blocking.** The reviewer replayed 14 mutations against the guard — YAML anchors/merge keys, `deploy.restart_policy` mistaken for `restart`, `restart` nested under another key, empty/null/`Always`-cased values, duplicate keys, unparseable YAML, and real-render deletions and templated-`no` — all handled correctly. Applied: `fullmatch` so a trailing newline cannot slip through (with a fixture), a corrected docstring, and matching the playbook task's `cmd:` line rather than merely its filename. **Declined:** loading `roles/docker/defaults` into the render test to remove the duplicated service list — variable-precedence risk, and `check-second-wave-services.sh` already pins the defaults at exactly 13 entries, so an added service forces edits in both places.

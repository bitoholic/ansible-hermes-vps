#!/usr/bin/env bash
# AdGuard DNS-serving guard (epic 18, ticket #05).
#
# This ticket's core risk (a host-level systemd-resolved change, sequenced
# against a live Docker container start) cannot be safely exercised in CI or a
# local dev sandbox — actually running it would mutate the real host's DNS
# resolver. Everything here is a STATIC check of the declared contract
# (site.yml task ordering, the task files' own sequencing, the firewall rules),
# mirroring how tests/check-tailscale.sh already treats live iptables/UFW
# behavior as operator-validated on the VPS, not something CI executes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=support/yaml_block_assertions.sh
source "$REPO_ROOT/tests/support/yaml_block_assertions.sh"

echo "== AdGuard DNS-serving guard =="

DNS_TASKS=roles/adguard/tasks/free_host_dns_port.yml
ADGUARD_MAIN=roles/adguard/tasks/main.yml
DOCKER_MAIN=roles/docker/tasks/main.yml
TS_TASKS=roles/tailscale/tasks/main.yml
ADGUARD_FRAGMENT=roles/docker/templates/services/adguard.yml.j2

# check_in/entry_has: shared helpers, see tests/support/yaml_block_assertions.sh
# (that file's own comment has the "why not a fixed grep -A window" history —
# this script is the one that originally found that bug empirically, fixed
# here first before tests/check-second-wave-services.sh hit the same thing).
# check_in's case-insensitivity is used below by the two README prose checks
# (matching a heading/phrase regardless of capitalization).

# line_of <file> <pattern> — first matching line number, or empty. Not part of
# the shared lib: unlike check_in/entry_has, nothing else in this repo needs
# it yet.
line_of() { grep -nE "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

# 1: correction #1 (found in code review) — AdGuard's container physically
# cannot bind host port 53 while systemd-resolved's stub listener still holds
# it, so the DNS handover must run BEFORE the stack starts, not after. A
# separate post-start wait_for confirms AdGuard actually bound the port
# (fail-fast, not sequencing safety).
[[ -f "$DNS_TASKS" ]] || { echo "FAIL: $DNS_TASKS does not exist"; exit 1; }
STACK_START_LINE="$(line_of site.yml 'Start consolidated docker compose stack')"
DNS_HANDOVER_LINE="$(line_of site.yml 'ansible\.builtin\.include_tasks: roles/adguard/tasks/free_host_dns_port\.yml')"
VERIFY_LINE="$(line_of site.yml 'AdGuard DNS: verify the container bound port 53')"
for pair in "STACK_START_LINE:the stack-start task" "DNS_HANDOVER_LINE:the DNS handover include_tasks" "VERIFY_LINE:the post-start port-53 verification"; do
  name="${pair##*:}"; var="${pair%%:*}"
  [[ -n "${!var}" ]] || { echo "FAIL: could not find $name in site.yml"; exit 1; }
done
if (( DNS_HANDOVER_LINE >= STACK_START_LINE )); then
  echo "FAIL: AdGuard DNS handover must run BEFORE the docker compose stack starts (handover=$DNS_HANDOVER_LINE, stack-start=$STACK_START_LINE) — AdGuard cannot bind port 53 while it's still busy"
  exit 1
fi
if (( VERIFY_LINE <= STACK_START_LINE )); then
  echo "FAIL: the port-53 verification must run AFTER the stack starts (verify=$VERIFY_LINE, stack-start=$STACK_START_LINE)"
  exit 1
fi
# A small window after each task's defining line, not a fixed single-line
# offset — robust to a `when:` guard line shifting where `tags:` lands.
HANDOVER_BLOCK="$(sed -n "${DNS_HANDOVER_LINE},$((DNS_HANDOVER_LINE+3))p" site.yml)"
VERIFY_BLOCK="$(sed -n "${VERIFY_LINE},$((VERIFY_LINE+5))p" site.yml)"

if ! grep -q 'tags: \[adguard\]' <<<"$HANDOVER_BLOCK"; then
  echo "FAIL: AdGuard DNS handover task is not tagged [adguard]"; exit 1
fi
echo "site.yml sequencing OK (DNS handover before stack-start, verification after)"

# 1b: both the handover and the verification must be guarded on adguard
# actually being enabled (caught in review) — otherwise an operator who
# excludes adguard from docker_enabled_services without also using
# --skip-tags adguard gets the host's DNS torn down for a container that will
# never exist to take over port 53. The condition is computed once (a play-level
# var, adguard_dns_enabled) and referenced by name in both places — not repeated
# as a literal string twice (caught in review; the two tasks can't share a
# single block: since the unconditional stack-start task sits between them).
check_in site.yml "adguard_dns_enabled:.*'adguard' in docker_enabled_services" "adguard_dns_enabled defined as 'adguard' in docker_enabled_services"
if ! grep -q 'when: adguard_dns_enabled' <<<"$HANDOVER_BLOCK"; then
  echo "FAIL: the DNS handover task is not guarded on adguard_dns_enabled"; exit 1
fi
if ! grep -q 'when: adguard_dns_enabled' <<<"$VERIFY_BLOCK"; then
  echo "FAIL: the port-53 verification task is not guarded on adguard_dns_enabled"; exit 1
fi
echo "docker_enabled_services guard OK (handover and verification both skip cleanly when adguard is disabled)"

# 2: the DNS handover task file's own internal order — drop-in written, THEN
# /etc/resolv.conf repointed, THEN restarted (Pi-hole's documented order:
# repointing after the restart leaves a window pointing at the dead stub
# symlink; DNS= in the drop-in is only honored through the non-stub file).
DROPIN_LINE="$(line_of "$DNS_TASKS" 'DNSStubListener=no')"
REPOINT_LINE="$(line_of "$DNS_TASKS" 'dest: /etc/resolv\.conf')"
RESTART_LINE="$(line_of "$DNS_TASKS" 'state: restarted')"
for pair in "DROPIN_LINE:the resolved.conf drop-in" "REPOINT_LINE:the resolv.conf repoint" "RESTART_LINE:the systemd-resolved restart"; do
  name="${pair##*:}"; var="${pair%%:*}"
  [[ -n "${!var}" ]] || { echo "FAIL: could not find $name in $DNS_TASKS"; exit 1; }
done
if (( REPOINT_LINE <= DROPIN_LINE )); then
  echo "FAIL: the resolv.conf repoint must come after the drop-in is written"; exit 1
fi
if (( RESTART_LINE <= REPOINT_LINE )); then
  echo "FAIL: the systemd-resolved restart must come after the resolv.conf repoint (Pi-hole's documented order)"; exit 1
fi
check_in "$DNS_TASKS" 'DNS=127\.0\.0\.1' "DNS=127.0.0.1 in the drop-in"
check_in "$DNS_TASKS" '/run/systemd/resolve/resolv\.conf' "repoint target (the non-stub file)"
echo "DNS handover task sequencing OK (drop-in -> repoint -> restart)"

# 3: correction #2 (found in code review) — once host DNS is down, "docker
# compose up" pulling a not-yet-cached image would need DNS it no longer has.
# Every enabled service's image must be pre-pulled while DNS still works,
# earlier in the same play (docker's own early tasks).
check_in "$DOCKER_MAIN" 'docker compose .* pull' "the image pre-pull step"
PREPULL_LINE="$(line_of "$DOCKER_MAIN" 'docker compose .* pull')"
RENDER_LINE="$(line_of "$DOCKER_MAIN" 'Render consolidated docker-compose\.yml')"
if (( PREPULL_LINE <= RENDER_LINE )); then
  echo "FAIL: the pre-pull step must come after docker-compose.yml is rendered (needs the file to exist)"; exit 1
fi
# --ignore-buildable is not optional (caught in review, verified against
# docker/compose#8805/#10134): without it, `docker compose pull` does not skip
# build-only services (hermes-agent) automatically — it tries to pull one
# anyway and fails, aborting this task and the whole play on every real run.
check_in "$DOCKER_MAIN" 'docker compose .* pull.*--ignore-buildable' "the pre-pull command missing --ignore-buildable (hermes-agent is build-only and would fail the pull otherwise)"
echo "image pre-pull step OK (present, after compose render, --ignore-buildable set, before host DNS is ever touched)"

# 4: this sequencing-critical logic must NOT live in the role's own early-phase
# tasks/main.yml — that runs during the config-deploying phase, well before the
# stack actually starts. A future "simplification" merging these back together
# would silently reintroduce the exact failure mode this ticket exists to avoid.
if grep -qE 'DNSStubListener|resolved\.conf\.d|systemd-resolved' "$ADGUARD_MAIN"; then
  echo "FAIL: $ADGUARD_MAIN must not contain systemd-resolved logic — it runs too early; see $DNS_TASKS"
  exit 1
fi
echo "early-phase/late-phase separation OK"

# 5: firewall — a UDP restricted-port class exists and is wired into
# DOCKER-USER (v4 and v6), mirroring the existing TCP restricted-port rules.
check_in group_vars/all/main.yml '^docker_published_restricted_udp_ports:' "docker_published_restricted_udp_ports defined"
entry_has group_vars/all/main.yml '^docker_published_restricted_udp_ports:' '  - 53' "53 in docker_published_restricted_udp_ports"
entry_has group_vars/all/main.yml '^docker_published_restricted_ports:' '  - 53' "53 in docker_published_restricted_ports (TCP, for DNS's TCP fallback)"
for rule in "DOCKER-USER v4 - restricted UDP ports from Tailscale subnet" \
            "DOCKER-USER v4 - restricted UDP ports denied for everyone else" \
            "DOCKER-USER v6 - restricted UDP ports from Tailscale ULA" \
            "DOCKER-USER v6 - restricted UDP ports denied for everyone else"; do
  check_in "$TS_TASKS" "$rule" "rule: $rule"
done
check_in "$TS_TASKS" 'protocol: udp' "at least one protocol: udp rule"
check_in "$TS_TASKS" 'docker_published_restricted_udp_ports' "UDP rules iterating docker_published_restricted_udp_ports"
echo "UDP restricted-port firewall contract OK"

# 6: the compose fragment publishes DNS on both protocols.
check_in "$ADGUARD_FRAGMENT" '"53:53/tcp"' "53:53/tcp published"
check_in "$ADGUARD_FRAGMENT" '"53:53/udp"' "53:53/udp published"
echo "compose fragment DNS publish OK"

# 7: the manual Tailscale-console step is documented for the operator, and
# explicitly distinguishes global-override-nameserver from split-DNS (ticket's
# own instruction — a future revisit should not re-investigate the wrong
# Tailscale feature).
check_in README.md 'Manual Post-Deploy Steps' "the Manual Post-Deploy Steps section"
check_in README.md 'global override nameserver' "the global override nameserver setting"
check_in README.md 'split DNS' "a distinction from split-DNS"
echo "manual DNS-override documentation OK"

echo "AdGuard DNS-serving guard OK"

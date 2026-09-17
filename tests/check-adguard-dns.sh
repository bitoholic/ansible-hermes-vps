#!/usr/bin/env bash
# AdGuard DNS-serving guard (epic 18, ticket #05).
#
# This ticket's core risk (a host-level systemd-resolved change, sequenced
# against a live Docker container start) cannot be safely exercised in CI or a
# local dev sandbox — actually running it would mutate the real host's DNS
# resolver. Everything here is a STATIC check of the declared contract
# (site.yml task ordering, the task file's own sequencing, the firewall rules),
# mirroring how tests/check-tailscale.sh already treats live iptables/UFW
# behavior as operator-validated on the VPS, not something CI executes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "== AdGuard DNS-serving guard =="

DNS_TASKS=roles/adguard/tasks/free_host_dns_port.yml
ADGUARD_MAIN=roles/adguard/tasks/main.yml
TS_TASKS=roles/tailscale/tasks/main.yml

# 1: site.yml must invoke the DNS handover task, tagged [adguard], strictly
# AFTER the stack-start step — never before, or the host's resolver could be
# torn down before AdGuard's container even exists.
STACK_START_LINE="$(grep -n 'Start consolidated docker compose stack' site.yml | head -1 | cut -d: -f1)"
DNS_HANDOVER_LINE="$(grep -n 'ansible.builtin.include_tasks: roles/adguard/tasks/free_host_dns_port.yml' site.yml | head -1 | cut -d: -f1)"
if [[ -z "$STACK_START_LINE" || -z "$DNS_HANDOVER_LINE" ]]; then
  echo "FAIL: could not find stack-start and/or DNS-handover task in site.yml"; exit 1
fi
if (( DNS_HANDOVER_LINE <= STACK_START_LINE )); then
  echo "FAIL: AdGuard DNS handover task must run AFTER the docker compose stack starts (handover=$DNS_HANDOVER_LINE, stack-start=$STACK_START_LINE)"
  exit 1
fi
if ! sed -n "$((DNS_HANDOVER_LINE+1))p" site.yml | grep -q 'tags: \[adguard\]'; then
  echo "FAIL: AdGuard DNS handover task is not tagged [adguard]"; exit 1
fi
echo "site.yml sequencing OK (DNS handover after stack-start)"

# 2: the DNS handover task file itself must sequence wait-for-port-53 BEFORE
# any systemd-resolved mutation, and the resolv.conf repoint BEFORE the
# restart (Pi-hole's own documented order — repointing after the restart
# leaves a window pointing at the dead stub symlink).
if [[ ! -f "$DNS_TASKS" ]]; then
  echo "FAIL: $DNS_TASKS does not exist"; exit 1
fi
WAIT_LINE="$(grep -n 'ansible.builtin.wait_for' "$DNS_TASKS" | head -1 | cut -d: -f1)"
DROPIN_LINE="$(grep -n 'DNSStubListener=no' "$DNS_TASKS" | head -1 | cut -d: -f1)"
REPOINT_LINE="$(grep -n 'dest: /etc/resolv.conf' "$DNS_TASKS" | head -1 | cut -d: -f1)"
RESTART_LINE="$(grep -n 'state: restarted' "$DNS_TASKS" | head -1 | cut -d: -f1)"
for pair in "WAIT_LINE:wait_for port 53" "DROPIN_LINE:the resolved.conf drop-in" "REPOINT_LINE:the resolv.conf repoint" "RESTART_LINE:the systemd-resolved restart"; do
  name="${pair##*:}"; var="${pair%%:*}"
  if [[ -z "${!var}" ]]; then
    echo "FAIL: could not find $name in $DNS_TASKS"; exit 1
  fi
done
if (( DROPIN_LINE <= WAIT_LINE )); then
  echo "FAIL: the resolved.conf drop-in must come after waiting for AdGuard to bind port 53"; exit 1
fi
if (( REPOINT_LINE <= DROPIN_LINE )); then
  echo "FAIL: the resolv.conf repoint must come after the drop-in is written"; exit 1
fi
if (( RESTART_LINE <= REPOINT_LINE )); then
  echo "FAIL: the systemd-resolved restart must come after the resolv.conf repoint (Pi-hole's documented order)"; exit 1
fi
if ! grep -q 'DNS=127.0.0.1' "$DNS_TASKS"; then
  echo "FAIL: $DNS_TASKS missing DNS=127.0.0.1 in the drop-in"; exit 1
fi
if ! grep -q '/run/systemd/resolve/resolv.conf' "$DNS_TASKS"; then
  echo "FAIL: $DNS_TASKS does not repoint /etc/resolv.conf at the non-stub file"; exit 1
fi
echo "DNS handover task sequencing OK (wait -> drop-in -> repoint -> restart)"

# 3: this sequencing-critical logic must NOT live in the role's own early-phase
# tasks/main.yml — that runs during the config-deploying phase, well before the
# stack actually starts. A future "simplification" merging these back together
# would silently reintroduce the exact failure mode this ticket exists to avoid.
if grep -q 'DNSStubListener\|resolved.conf.d\|systemd-resolved' "$ADGUARD_MAIN"; then
  echo "FAIL: $ADGUARD_MAIN must not contain systemd-resolved logic — it runs too early (before the docker stack starts); see $DNS_TASKS"
  exit 1
fi
echo "early-phase/late-phase separation OK"

# 4: firewall — a UDP restricted-port class exists and is wired into DOCKER-USER
# (v4 and v6), mirroring the existing TCP restricted-port rules' structure.
if ! grep -q '^docker_published_restricted_udp_ports:' group_vars/all/main.yml; then
  echo "FAIL: docker_published_restricted_udp_ports not defined in group_vars/all/main.yml"; exit 1
fi
if ! grep -A3 '^docker_published_restricted_udp_ports:' group_vars/all/main.yml | grep -q '  - 53'; then
  echo "FAIL: docker_published_restricted_udp_ports does not include 53"; exit 1
fi
if ! grep -A8 '^docker_published_restricted_ports:' group_vars/all/main.yml | grep -q '  - 53'; then
  echo "FAIL: docker_published_restricted_ports (TCP) does not also include 53 (DNS TCP fallback)"; exit 1
fi
for rule in "DOCKER-USER v4 - restricted UDP ports from Tailscale subnet" \
            "DOCKER-USER v4 - restricted UDP ports denied for everyone else" \
            "DOCKER-USER v6 - restricted UDP ports from Tailscale ULA" \
            "DOCKER-USER v6 - restricted UDP ports denied for everyone else"; do
  if ! grep -q "$rule" "$TS_TASKS"; then
    echo "FAIL: $TS_TASKS missing rule: $rule"; exit 1
  fi
done
if ! grep -q "protocol: udp" "$TS_TASKS"; then
  echo "FAIL: $TS_TASKS has no protocol: udp rules at all"; exit 1
fi
if ! grep -q "docker_published_restricted_udp_ports" "$TS_TASKS"; then
  echo "FAIL: $TS_TASKS UDP rules do not iterate docker_published_restricted_udp_ports"; exit 1
fi
echo "UDP restricted-port firewall contract OK"

# 5: the compose fragment publishes DNS on both protocols.
ADGUARD_FRAGMENT=roles/docker/templates/services/adguard.yml.j2
if ! grep -q '"53:53/tcp"' "$ADGUARD_FRAGMENT" || ! grep -q '"53:53/udp"' "$ADGUARD_FRAGMENT"; then
  echo "FAIL: $ADGUARD_FRAGMENT does not publish 53:53 on both tcp and udp"; exit 1
fi
echo "compose fragment DNS publish OK"

# 6: the manual Tailscale-console step is documented for the operator, and
# explicitly distinguishes global-override-nameserver from split-DNS (ticket's
# own instruction — a future revisit should not re-investigate the wrong
# Tailscale feature).
if ! grep -q "Manual Post-Deploy Steps" README.md; then
  echo "FAIL: README.md missing the Manual Post-Deploy Steps section"; exit 1
fi
if ! grep -qi "global override nameserver" README.md; then
  echo "FAIL: README.md does not document the global override nameserver setting"; exit 1
fi
if ! grep -qi "split DNS" README.md; then
  echo "FAIL: README.md does not distinguish global override from split-DNS"; exit 1
fi
echo "manual DNS-override documentation OK"

echo "AdGuard DNS-serving guard OK"

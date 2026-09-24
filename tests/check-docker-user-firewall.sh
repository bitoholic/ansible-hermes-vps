#!/usr/bin/env bash
# Epic 21 ticket #02 guard: boot-persistent, atomic DOCKER-USER rules + the boot firewall unit.
#
# Asserts on OBSERVABLE BEHAVIOR of the rendered artifacts — which ports end up public,
# tailnet-only (per protocol and family) or allowlisted — not on how the role's tasks are spelled.
# Static (always runs):
#   1. Rendered rules classify ports correctly for both families, from the shared port-class
#      variables (public / restricted TCP / restricted UDP / Syncplay allowlist).
#   2. Each ruleset touches ONLY the DOCKER-USER chain (one table, one declared chain, no flush of
#      anything else) so loading it can never disturb UFW, INPUT or Docker's own chains.
#   3. Rendering is byte-stable (idempotent).
#   4. The boot unit is ordered before Docker, follows Docker restarts, and is enabled at boot.
#   5. The fail-closed coupling is a hard Requires= when enabled (default on since the drill) and absent when disabled.
#   6. The role deploys these via one shared loader, no longer builds the chain with per-rule tasks,
#      and a deploy heals an unchanged artifact by comparing the live chain, not the files.
# Live (guarded; runs only when podman and the disposable image are present):
#   the same loader run inside the epic-21 spike container — applying, re-applying (identical),
#   healing a flushed chain, and leaving Docker's own chains alone.
#
# What this CANNOT verify: that the rules survive a real reboot or a real Docker restart on the VPS,
# or the measured boot window. Those are operator-validated in the attended reboot drill (ticket #06),
# per this repo's practice for anything needing live network state.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false

fail() { echo "FAIL: $*" >&2; exit 1; }
echo "== docker-user firewall guard (epic 21 #02) =="

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render() {  # render <dir> [extra-vars-json]
  local dir="$1"; local extra="${2:-{\}}"
  ansible-playbook tests/test_docker_user_rules.yml -e "render_dir=$dir" -e "$extra" >"$TMP/ansible.log" 2>&1 \
    || { cat "$TMP/ansible.log" >&2; fail "render playbook failed ($dir)"; }
}

# port classes used by the fixtures (kept explicit so the assertions read like the requirement)
FIX_DEFAULT='{}'
FIX_CUSTOM='{"docker_published_public_ports":[80,443],"docker_published_restricted_ports":[3000,9119],"docker_published_restricted_udp_ports":[53],"syncplay_allowed_ips":["203.0.113.7","203.0.113.8"],"tailscale_subnet":"100.64.0.0/10","tailscale_subnet_v6":"fd7a:115c:a1e0::/48"}'
FIX_NO_SYNCPLAY='{"syncplay_allowed_ips":[]}'
FIX_FAILCLOSED='{"tailscale_docker_user_firewall_fail_closed":true}'

render "$TMP/default" "$FIX_DEFAULT"
render "$TMP/custom" "$FIX_CUSTOM"
render "$TMP/nosync" "$FIX_NO_SYNCPLAY"
render "$TMP/failclosed" "$FIX_FAILCLOSED"

# line number of the first line in <file> matching <pattern> (empty if none)
lineno() { grep -nE -e "$2" "$1" | head -1 | cut -d: -f1; }
must() { local f=$1 pat=$2 what=$3; [[ -n "$(lineno "$f" "$pat")" ]] || fail "$(basename "$f"): missing $what"; }
mustnot() { local f=$1 pat=$2 what=$3; [[ -z "$(lineno "$f" "$pat")" ]] || fail "$(basename "$f"): unexpected $what"; }
# accept-before-drop: the ACCEPT for a port must appear on an earlier line than its DROP
accept_before_drop() { # file proto port src-pattern what
  local f=$1 proto=$2 port=$3 src=$4 what=$5 a d
  a=$(lineno "$f" "^-A DOCKER-USER -s ${src} -p ${proto} -m ${proto} --dport ${port} .*-j ACCEPT")
  d=$(lineno "$f" "^-A DOCKER-USER -p ${proto} -m ${proto} --dport ${port} .*-j DROP")
  [[ -n "$a" && -n "$d" && "$a" -lt "$d" ]] || fail "$(basename "$f"): $what (accept line='${a}', drop line='${d}')"
}

# ---- 1. classification, custom fixture (explicit expectations) -------------------------------
V4="$TMP/custom/docker-user.v4.rules"; V6="$TMP/custom/docker-user.v6.rules"
for p in 3000 9119; do
  accept_before_drop "$V4" tcp "$p" '100\.64\.0\.0/10' "v4 tcp $p must be tailnet-accept then drop-others"
  accept_before_drop "$V6" tcp "$p" 'fd7a:115c:a1e0::/48' "v6 tcp $p must be tailnet-accept then drop-others"
done
accept_before_drop "$V4" udp 53 '100\.64\.0\.0/10' "v4 udp 53 must be tailnet-accept then drop-others"
accept_before_drop "$V6" udp 53 'fd7a:115c:a1e0::/48' "v6 udp 53 must be tailnet-accept then drop-others"
for p in 80 443; do
  must "$V4" "^-A DOCKER-USER -p tcp -m tcp --dport $p .*-j ACCEPT" "v4 public port $p accepted from anywhere"
  must "$V6" "^-A DOCKER-USER -p tcp -m tcp --dport $p .*-j ACCEPT" "v6 public port $p accepted from anywhere"
  mustnot "$V4" "^-A DOCKER-USER .*--dport $p .*-j DROP" "drop rule for public port $p"
done
# a port that is in no class gets no rule at all (Docker's own forwarding decides)
mustnot "$V4" "--dport 5432" "rule for an unclassified port"
# Syncplay: allowlisted IPs accepted (v4), everyone else dropped; IPv6 blocked outright
must "$V4" "^-A DOCKER-USER -s 203\.0\.113\.7(/32)? -p tcp -m tcp --dport 8999 .*-j ACCEPT" "syncplay allow for first allowlisted IP"
must "$V4" "^-A DOCKER-USER -s 203\.0\.113\.8(/32)? -p tcp -m tcp --dport 8999 .*-j ACCEPT" "syncplay allow for second allowlisted IP"
accept_before_drop "$V4" tcp 8999 '203\.0\.113\.7(/32)?' "syncplay allowlist accept must precede the catch-all drop"
must "$V6" "^-A DOCKER-USER -p tcp -m tcp --dport 8999 .*-j DROP" "v6 syncplay dropped (allowlist is IPv4-only)"
mustnot "$V6" "203\.0\.113" "an IPv4 allowlist address in the v6 ruleset"
mustnot "$V6" "^-A DOCKER-USER -s .* --dport 8999 .*-j ACCEPT" "any v6 syncplay accept"
# an empty allowlist means the port is fully blocked
NS="$TMP/nosync/docker-user.v4.rules"
must "$NS" "^-A DOCKER-USER -p tcp -m tcp --dport 8999 .*-j DROP" "syncplay drop with an empty allowlist"
mustnot "$NS" "--dport 8999 .*-j ACCEPT" "syncplay accept with an empty allowlist"
# docker-bridge and established traffic return/accept before any port classification
for f in "$V4" "$V6"; do
  br=$(lineno "$f" '^-A DOCKER-USER -i br\+ .*-j RETURN'); dk=$(lineno "$f" '^-A DOCKER-USER -i docker\+ .*-j RETURN')
  est=$(lineno "$f" 'RELATED,ESTABLISHED .*-j ACCEPT'); first_port=$(lineno "$f" '--dport')
  [[ -n "$br" && -n "$dk" && -n "$est" && -n "$first_port" ]] || fail "$(basename "$f"): missing bridge-return / established accept"
  (( br < first_port && dk < first_port && est < first_port )) || fail "$(basename "$f"): bridge/established rules must precede port classification"
done
echo "port classification OK (v4 + v6; public / restricted tcp+udp / syncplay allowlist)"

# ---- 1b. the DEFAULT render must follow the real group_vars (no fixture ports hardcoded) ----
# Every class is checked against the real variables for BOTH families: public ports accepted and never
# dropped; restricted TCP/UDP ports accept-from-tailnet-then-drop (incl. the templated conduit_port).
python3 - "$TMP/default" <<'PY' || exit 1
import re,sys,yaml
d=yaml.safe_load(open("group_vars/all/main.yml")); out=sys.argv[1]
def val(p):
    if isinstance(p,int): return p
    m=re.fullmatch(r"\{\{\s*(\w+)\s*\}\}",str(p)); return d[m.group(1)]
pub=[val(p) for p in d["docker_published_public_ports"]]
rt=[val(p) for p in d["docker_published_restricted_ports"]]
ru=[val(p) for p in d.get("docker_published_restricted_udp_ports",[])]
src={"v4":re.escape(d["tailscale_subnet"]),"v6":re.escape(d["tailscale_subnet_v6"])}
def idx(lines,pat):
    for i,l in enumerate(lines):
        if re.search(pat,l): return i
bad=[]
for fam in ("v4","v6"):
    L=[l for l in open(f"{out}/docker-user.{fam}.rules").read().split("\n") if l.startswith("-A DOCKER-USER")]
    for p in pub:
        if idx(L,rf"-p tcp -m tcp --dport {p} .*-j ACCEPT") is None: bad.append(f"{fam}: public {p} not accepted")
        if idx(L,rf"^-A DOCKER-USER -p tcp -m tcp --dport {p} .*-j DROP") is not None: bad.append(f"{fam}: public {p} is dropped")
    for proto,ports in (("tcp",rt),("udp",ru)):
        for p in ports:
            a=idx(L,rf"^-A DOCKER-USER -s {src[fam]} -p {proto} -m {proto} --dport {p} .*-j ACCEPT")
            x=idx(L,rf"^-A DOCKER-USER -p {proto} -m {proto} --dport {p} .*-j DROP")
            if a is None or x is None or a>=x: bad.append(f"{fam}: restricted {proto}/{p} not accept-then-drop (accept={a}, drop={x})")
if bad: print("\n".join(bad)); sys.exit(1)
print(f"  default render: {len(pub)} public, {len(rt)} restricted tcp, {len(ru)} restricted udp ports verified on v4 and v6")
PY
echo "default render follows the shared port-class variables OK (all classes, both families)"

# ---- 2. blast radius: only the DOCKER-USER chain in the filter table -------------------------
for f in "$TMP"/default/docker-user.v4.rules "$TMP"/default/docker-user.v6.rules; do
  [[ "$(grep -c '^\*' "$f")" == 1 && "$(grep -c '^\*filter$' "$f")" == 1 ]] || fail "$(basename "$f"): must declare exactly the filter table"
  [[ "$(grep -c '^:' "$f")" == 1 && "$(grep -c '^:DOCKER-USER - \[0:0\]$' "$f")" == 1 ]] || fail "$(basename "$f"): must declare exactly the DOCKER-USER chain"
  [[ "$(grep -c '^COMMIT$' "$f")" == 1 ]] || fail "$(basename "$f"): must have exactly one COMMIT"
  if grep -E '^-(F|X|P|N|I|D|R|Z) ' "$f" >/dev/null; then fail "$(basename "$f"): may only append (-A) to DOCKER-USER, found another operation"; fi
  if grep -E '^-A ' "$f" | grep -vqE '^-A DOCKER-USER '; then fail "$(basename "$f"): a rule targets a chain other than DOCKER-USER"; fi
  if grep -v '^#' "$f" | grep -qE -e '-j (ufw[a-z0-9-]*|INPUT|OUTPUT|FORWARD)( |$)' -e '--dport 22( |$)'; then fail "$(basename "$f"): must not reference UFW/INPUT/OUTPUT/FORWARD/ssh"; fi
done
echo "blast radius OK (one table, one chain, append-only, no UFW/INPUT/ssh)"

# ---- 3. byte-stable rendering ----------------------------------------------------------------
render "$TMP/default2" "$FIX_DEFAULT"
for f in docker-user.v4.rules docker-user.v6.rules hermes-docker-user-firewall.service; do
  cmp -s "$TMP/default/$f" "$TMP/default2/$f" || fail "$f: rendering is not byte-stable across runs"
done
echo "rendering is byte-stable OK"

# ---- 4. boot unit ----------------------------------------------------------------------------
U="$TMP/default/hermes-docker-user-firewall.service"
must "$U" '^Type=oneshot$' "Type=oneshot"
must "$U" '^RemainAfterExit=yes$' "RemainAfterExit=yes"
must "$U" '^Before=docker\.service$' "ordered Before=docker.service (rules exist before the daemon starts containers)"
must "$U" '^PartOf=docker\.service$' "PartOf=docker.service (a Docker restart re-runs the loader)"
must "$U" '^WantedBy=.*multi-user\.target' "enabled at boot (WantedBy=multi-user.target)"
must "$U" '^WantedBy=.*docker\.service' "pulled in by docker.service (so a Docker (re)start loads the rules first)"
must "$U" '^ExecStart=/usr/local/sbin/hermes-docker-user-rules apply$' "ExecStart runs the shared loader"
# An After=/Requires= on docker.service would CONTRADICT Before=docker.service (an ordering cycle systemd breaks by
# dropping a job — possibly leaving Docker up without the rules).
if grep -v '^#' "$U" | grep -qE '^(After|Requires|Wants|BindsTo)=.*docker\.service'; then fail "the boot unit must not be ordered after / depend on docker.service (Before= only)"; fi
# SuccessExitStatus= / ExecStart=- would make a FAILED load look active, defeating the fail-closed coupling.
if grep -v '^#' "$U" | grep -qE '^(SuccessExitStatus=|ExecStart=-)'; then fail "the boot unit must not mask a failed load (SuccessExitStatus= / ExecStart=-)"; fi
# PartOf=docker.service propagates a Docker stop/restart to this unit; if it had an ExecStop that touched the
# chain, every Docker restart would EMPTY the chain (found while reviewing the epic 21 spike).
if grep -v '^#' "$U" | grep -qE '^(ExecStop|ExecStopPost|ExecReload)='; then fail "the boot unit must have no ExecStop/ExecStopPost — a Docker restart propagates a stop to it"; fi
if grep -v '^#' "$U" | grep -qiE 'ufw|sshd|ssh\.service|INPUT'; then fail "boot unit must not reference UFW/sshd/INPUT"; fi
grep -q 'do NOT' "$U" && grep -q 'hermes-docker-user-rules' "$U" || fail "the unit must tell operators to reload via the loader, not by restarting the unit (which restarts Docker under the fail-closed coupling)"
grep -q 'hermes-docker-user-rules apply' README.md && grep -q 'restart hermes-docker-user-firewall' README.md \
  || fail "README must document reloading with the loader and warn against restarting the unit"
echo "boot unit OK"

# ---- 5. fail-closed coupling (BEHAVIOR: evaluate the tasks' own gating) ---------------------
grep -q '^tailscale_docker_user_firewall_fail_closed: true' roles/tailscale/defaults/main.yml || fail "fail-closed coupling must default to enabled (enabled by the reboot drill, epic 21 #06; a deploy with it false removes the drop-in)"
FC="$TMP/failclosed/docker-fail-closed.conf"
must "$FC" '^Requires=hermes-docker-user-firewall\.service$' "hard Requires= on the firewall unit when the coupling is enabled"
must "$FC" '^After=hermes-docker-user-firewall\.service$' "After= on the firewall unit"
TS=roles/tailscale/tasks/main.yml
# Evaluate the real `when:` of the install/remove tasks for both values of the switch. A textual grep passes
# even with the gating INVERTED — which would put the untested Requires= coupling on production by default.
python3 - "$TS" <<'PY' || exit 1
import sys,yaml,jinja2
tasks=yaml.safe_load(open(sys.argv[1]))
def task(prefix):
    m=[t for t in tasks if t.get("name","").startswith(prefix)]; assert len(m)==1,(prefix,len(m)); return m[0]
install=task("Install the fail-closed coupling drop-in"); remove=task("Remove the fail-closed coupling drop-in")
assert install["ansible.builtin.template"]["dest"]==remove["ansible.builtin.file"]["path"], "install and remove must target the same drop-in file"
assert remove["ansible.builtin.file"]["state"]=="absent"
env=jinja2.Environment(); env.filters["bool"]=lambda v: str(v).strip().lower() in ("true","1","yes","on")
def holds(cond,value):
    expr=cond if isinstance(cond,str) else " and ".join(f"({c})" for c in cond)
    return env.from_string("{{ %s }}"%expr).render(tailscale_docker_user_firewall_fail_closed=value)=="True"
for value,want_install,want_remove in ((False,False,True),(True,True,False)):
    got_i,got_r=holds(install["when"],value),holds(remove["when"],value)
    assert (got_i,got_r)==(want_install,want_remove), f"switch={value}: install={got_i} remove={got_r}, expected install={want_install} remove={want_remove}"
print("  drop-in gating: disabled -> removed and not installed; enabled -> installed and not removed")
PY
echo "fail-closed coupling OK (default on after the drill; install/remove gating evaluated for both switch values)"

# ---- 6. role wiring --------------------------------------------------------------------------
if grep -q 'ansible.builtin.iptables' "$TS"; then fail "tailscale role still builds the chain with per-rule iptables tasks"; fi
grep -q 'hermes-docker-user-rules' "$TS" || fail "tasks do not deploy the shared loader"
grep -q 'docker-user.rules' "$TS" || fail "tasks do not deploy the rendered rules"
grep -q 'hermes-docker-user-firewall' "$TS" || fail "tasks do not install the boot unit"
[[ -x roles/tailscale/files/hermes-docker-user-rules ]] || fail "the shared loader script must be executable"
# BOTH families must be loaded with --noflush: without it restore FLUSHES THE WHOLE FILTER TABLE (UFW's and
# Docker's chains too) on every deploy and boot.
LOADER=roles/tailscale/files/hermes-docker-user-rules
[[ "$(grep -cE '^ +(ip6?tables-restore) --noflush < "\$V[46]"$' "$LOADER")" == 2 ]] || fail "loader must load BOTH families with exactly: <iptables-restore|ip6tables-restore> --noflush < \"\$V4|V6\""
[[ "$(grep -cE '^ +ip6?tables-restore --noflush --test < "\$V[46]"$' "$LOADER")" == 2 ]] || fail "loader must --test-validate BOTH families first"
# each restore tool is tied to ITS OWN family's file (a v4 tool cannot parse a v6 file — and vice versa)
grep -qE '^ +iptables-restore --noflush < "\$V4"$' "$LOADER" && grep -qE '^ +ip6tables-restore --noflush < "\$V6"$' "$LOADER" \
  && grep -qE '^ +iptables-restore --noflush --test < "\$V4"$' "$LOADER" && grep -qE '^ +ip6tables-restore --noflush --test < "\$V6"$' "$LOADER" \
  || fail "loader must pair iptables-restore with \$V4 and ip6tables-restore with \$V6 (load and --test)"
if grep -E 'ip6?tables-restore' "$LOADER" | grep -vq -- '--noflush'; then fail "every ip[6]tables-restore in the loader must use --noflush"; fi
grep -q '^set -eu$' "$LOADER" || fail "loader must run with set -eu"
# the rendered rules files are validated BEFORE being installed, per family (a bad file must never land on disk)
python3 - "$TS" <<'PY' || exit 1
import sys,yaml
tasks=yaml.safe_load(open(sys.argv[1]))
def modeof(prefix,module):
    m=[x for x in tasks if x.get("name","").startswith(prefix)]; assert len(m)==1,prefix
    return m[0][module]
# root-executed boot code and the rules it loads must never be group/world-writable, and owned by root
for prefix,module in (("Ensure the DOCKER-USER firewall directory","ansible.builtin.file"),("Render the DOCKER-USER rules","ansible.builtin.template"),
                      ("Install the shared DOCKER-USER loader","ansible.builtin.copy"),("Install the boot firewall unit","ansible.builtin.template")):
    d=modeof(prefix,module); mode=int(str(d["mode"]),8)
    assert mode & 0o022==0, f"{prefix}: installed mode {d['mode']} is group/world-writable"
    assert d.get("owner")=="root" and d.get("group")=="root", f"{prefix}: must be owned by root"
t=[x for x in tasks if x.get("name","").startswith("Render the DOCKER-USER rules")][0]
import jinja2
v=t["ansible.builtin.template"].get("validate","")
def rendered(item): return jinja2.Environment().from_string(v).render(item=item)
v4,v6=rendered("v4"),rendered("v6")
assert v4.startswith("iptables-restore ") and "--test" in v4 and "%s" in v4, f"v4 file must be validated by iptables-restore: {v4!r}"
assert v6.startswith("ip6tables-restore ") and "--test" in v6 and "%s" in v6, f"v6 file must be validated by ip6tables-restore (a v4 tool cannot parse it): {v6!r}"
en=[x for x in tasks if x.get("name","").startswith("Enable the boot firewall unit")][0]["ansible.builtin.systemd"]
assert en.get("enabled") in (True,"true") and en.get("state")=="started", "boot unit must be enabled and started"
PY
# The heal-detection task is EXECUTED below in the live section (a text grep passes even when it always says
# 'changed'); statically, insist it is a real before/after comparison of the live chain.
python3 - "$TS" <<'PY' || exit 1
import sys,yaml
t=[x for x in yaml.safe_load(open(sys.argv[1])) if x.get("name","").startswith("Load the DOCKER-USER rules atomically")][0]
c=t["ansible.builtin.shell"]["cmd"]
assert c.lstrip().startswith("set -eu"), "heal task must start with set -eu: without it a FAILED apply is swallowed (the last command is an if, which returns 0) and the deploy reports success with the chain never loaded"
assert "status" in c and "apply" in c and '"$_before" != "$_after"' in c and "CHANGED" in c, "heal task must compare the live chain before/after apply"
assert "CHANGED" in t["changed_when"], "changed_when must key off the comparison"
PY
echo "role wiring OK"

echo "docker-user firewall guard OK"

# ---- live (guarded): the real loader and the real deploy heal-task, inside the disposable container ----
IMG=hermes-spike-docker
if command -v podman >/dev/null 2>&1 && podman image exists "$IMG" 2>/dev/null; then
  echo "== live: shared loader + heal task in the disposable container =="
  LIVE="$TMP/live"; mkdir -p "$LIVE"; cp "$TMP/default/docker-user.v4.rules" "$TMP/default/docker-user.v6.rules" "$LIVE/"
  # the deploy's heal task, rendered exactly as Ansible would (the loader path substituted), runnable under sh
  python3 - "$TS" > "$LIVE/heal.sh" <<'PY'
import sys,yaml,jinja2
t=[x for x in yaml.safe_load(open(sys.argv[1])) if x.get("name","").startswith("Load the DOCKER-USER rules atomically")][0]
print(jinja2.Environment().from_string(t["ansible.builtin.shell"]["cmd"]).render(tailscale_docker_user_firewall_loader="/usr/local/sbin/hermes-docker-user-rules"))
PY
  timeout 150 podman run --rm --privileged --network=private \
    -e HERMES_FIREWALL_DIR=/rules \
    -v "$LIVE:/rules:ro" -v "$REPO_ROOT/roles/tailscale/files/hermes-docker-user-rules:/usr/local/sbin/hermes-docker-user-rules:ro" \
    "$IMG" bash -euo pipefail -c '
      L=/usr/local/sbin/hermes-docker-user-rules
      $L test                                    # syntax-valid for both families
      $L apply; a="$($L status)"
      $L apply; b="$($L status)"
      [[ "$a" == "$b" ]] || { echo "FAIL: chain differs after a second apply"; exit 1; }
      [[ "$(iptables -S DOCKER-USER | wc -l)" -gt 3 ]] || { echo "FAIL: v4 chain not populated"; exit 1; }
      [[ "$(ip6tables -S DOCKER-USER | wc -l)" -gt 3 ]] || { echo "FAIL: v6 chain not populated"; exit 1; }
      iptables -F DOCKER-USER; ip6tables -F DOCKER-USER          # simulate a reboot / lost rules
      [[ "$($L status)" != "$a" ]] || { echo "FAIL: flush did not change the chain"; exit 1; }
      $L apply; [[ "$($L status)" == "$a" ]] || { echo "FAIL: apply did not heal a flushed chain"; exit 1; }
      iptables -N SPIKE-OTHER; iptables -A SPIKE-OTHER -j RETURN; keep="$(iptables -S SPIKE-OTHER)"
      ip6tables -N SPIKE-OTHER6; ip6tables -A SPIKE-OTHER6 -j RETURN; keep6="$(ip6tables -S SPIKE-OTHER6)"
      $L apply; [[ "$(iptables -S SPIKE-OTHER)" == "$keep" ]] || { echo "FAIL: loader disturbed a v4 chain it does not own"; exit 1; }
      # the v6 load must be --noflush too: without it the whole v6 filter table (UFW, Docker) would be wiped
      [[ "$(ip6tables -S SPIKE-OTHER6)" == "$keep6" ]] || { echo "FAIL: loader disturbed a v6 chain it does not own (v6 --noflush missing?)"; exit 1; }
      # status: a MISSING chain is just empty (rc 0), it must not be reported as an error
      iptables -F DOCKER-USER; iptables -X DOCKER-USER; ip6tables -F DOCKER-USER; ip6tables -X DOCKER-USER
      $L status >/dev/null || { echo "FAIL: status errored on a missing chain (should read as empty)"; exit 1; }
      $L apply; [[ "$($L status)" == "$a" ]] || { echo "FAIL: apply did not recreate a deleted chain"; exit 1; }
      echo "  loader OK: syntax, idempotent, heals a flushed chain, leaves other chains alone"

      # --- the deploy HEAL TASK itself (behavior, not text): reports changed exactly when the live chain differed
      out="$(sh /rules/heal.sh)"; [[ -z "$out" ]] || { echo "FAIL: heal task reported a change on an already-correct chain: $out"; exit 1; }
      iptables -F DOCKER-USER; ip6tables -F DOCKER-USER
      out="$(sh /rules/heal.sh)"; [[ "$out" == *CHANGED* ]] || { echo "FAIL: heal task did not report the emptied chain as changed"; exit 1; }
      [[ "$($L status)" == "$a" ]] || { echo "FAIL: heal task did not restore the chain"; exit 1; }
      echo "  heal task OK: silent when nothing drifted, reports CHANGED and restores when the chain was emptied"

      # --- validate BOTH families before changing either: a corrupt v6 file must leave the (different) v4 file UNapplied
      mkdir -p /bad; cp /rules/docker-user.v4.rules /bad/; cp /rules/docker-user.v6.rules /bad/
      sed -i "s#^COMMIT#-A DOCKER-USER -p tcp -m tcp --dport 12345 -j DROP\nCOMMIT#" /bad/docker-user.v4.rules   # a valid, DIFFERENT v4 ruleset
      echo "this is not a ruleset" > /bad/docker-user.v6.rules                                                  # a corrupt v6 ruleset
      before="$($L status)"
      if HERMES_FIREWALL_DIR=/bad $L apply 2>/dev/null; then echo "FAIL: apply succeeded with a corrupt v6 file"; exit 1; fi
      [[ "$($L status)" == "$before" ]] || { echo "FAIL: apply changed the v4 chain although the v6 file was corrupt (validate-both-first broken)"; exit 1; }
      echo "  validate-both OK: a corrupt v6 file changed nothing, not even the valid v4 file"

      # --- failure propagation: a FAILED apply must fail the heal task (else the deploy "succeeds" with no rules loaded)
      if HERMES_FIREWALL_DIR=/bad sh /rules/heal.sh >/dev/null 2>&1; then echo "FAIL: the heal task reported success although apply failed (set -eu missing?)"; exit 1; fi
      echo "  failure propagation OK: a failing apply fails the heal task"
    ' || fail "live loader/heal check failed in the disposable container"
  echo "live checks OK"
else
  echo "########################################################################################"
  echo "## WARNING: live loader/heal/validate-both checks SKIPPED — podman or the '$IMG' image is missing."
  echo "## They are the only tests that EXECUTE the loader and the deploy's heal logic. Build the image with"
  echo "##   .scratch/21-reboot-resilience/spike/run.sh build   (then re-run this guard)."
  echo "########################################################################################"
fi

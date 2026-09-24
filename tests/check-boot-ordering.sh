#!/usr/bin/env bash
# Epic 21 ticket #04 guard: boot ordering, late-dependency tolerance, single-owner host DNS,
# and the runtime-state audit.
#
# Asserts on behavior:
#   1. Docker is ordered AFTER tailscaled by an ordering-only drop-in — no Requires/Wants/BindsTo/PartOf/
#      Requisite — so a stopped or failed Tailscale can never keep Docker from starting.
#   2. The host-DNS ownership switch is ON by default since the drill (both values are still tested), and its decision table holds: disabled leaves a
#      working resolver as found, repoints only when the current file would be broken; enabled takes ownership.
#   3. The resolver drop-in keeps AdGuard first; the public fallbacks follow in order only when enabled, and
#      the stub listener is always disabled (AdGuard needs port 53).
#   4. Tasks: Tailscale is told to stop managing host DNS only under the switch; `tailscale up` restates it;
#      nothing here touches sshd or UFW.
#   5. docs/reboot-resilience.md covers every enabled service with a stated bound, states the DNS bounds for
#      the stopped AND hung cases, and holds the runtime-state audit.
#
# What this CANNOT verify: real systemd ordering, that Tailscale actually releases resolv.conf, the measured
# stopped/hung DNS delays, or a service's real convergence after a reboot. Those are operator-validated in the
# attended reboot drill (ticket #06), per this repo's practice for live host state.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "== boot ordering / host DNS guard (epic 21 #04) =="

render() { ansible-playbook tests/test_boot_ordering.yml -e "render_dir=$1" "${@:2}" >"$TMP/ansible.log" 2>&1 || { cat "$TMP/ansible.log" >&2; fail "render/decision-table playbook failed ($1)"; }; }
render "$TMP/off"
render "$TMP/on" -e render_owner_enabled=true

# ---- 1. ordering-only docker drop-in ------------------------------------------------------------
D="$TMP/off/docker-after-tailscaled.conf"
grep -qx 'After=tailscaled.service' "$D" || fail "docker drop-in must contain After=tailscaled.service"
if grep -v '^#' "$D" | grep -qE '^(Requires|Wants|BindsTo|PartOf|Requisite|Upholds|Conflicts)='; then
  fail "docker drop-in must be ORDERING ONLY (found a dependency directive) — a Tailscale outage must not block Docker"
fi
TS=roles/tailscale/tasks/main.yml
grep -q 'docker-after-tailscaled.conf.j2' "$TS" || fail "tailscale role does not install the ordering drop-in"
grep -qE 'dest: /etc/systemd/system/docker\.service\.d/20-hermes-after-tailscaled\.conf$' "$TS" || fail "ordering drop-in must be installed at exactly docker.service.d/20-hermes-after-tailscaled.conf (a renamed/.disabled file would be ignored by systemd)"
echo "docker ordered after tailscaled, ordering only OK"

# ---- 2. switch default ---------------------------------------------------------------------------
grep -qE '^host_dns_resolver_owner_enabled: true$' group_vars/all/main.yml || fail "host_dns_resolver_owner_enabled must default to true (enabled by the reboot drill, epic 21 #06)"
echo "host-DNS ownership: enabled by the drill (default on); both switch values still tested; repoint decision table passed in the playbook"

# ---- 3. resolved drop-in ------------------------------------------------------------------------
R_OFF="$TMP/off/resolved-adguardhome.conf"; R_ON="$TMP/on/resolved-adguardhome.conf"
grep -qx 'DNSStubListener=no' "$R_OFF" && grep -qx 'DNSStubListener=no' "$R_ON" || fail "the stub listener must always be disabled (AdGuard needs port 53)"
# With the switch OFF the rendered drop-in must be BYTE-IDENTICAL to the one this role has always written, so a
# routine deploy leaves it exactly as found (no rewrite, no systemd-resolved restart).
printf '[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no\n' | cmp -s - "$R_OFF" || fail "disabled: the drop-in must be byte-identical to the legacy one"
grep -qx 'DNS=127.0.0.1' "$R_OFF" || fail "disabled: DNS= must be exactly AdGuard (127.0.0.1), as before"
grep -qx 'DNS=127.0.0.1 9.9.9.9 149.112.112.112' "$R_ON" || fail "enabled: DNS= must be AdGuard first, then the fallbacks in order (got: $(grep '^DNS=' "$R_ON"))"
if grep -qE '^FallbackDNS=' "$R_ON"; then fail "FallbackDNS= is ignored while DNS= is set; fallbacks must be ordinary DNS= servers"; fi
echo "resolver drop-in OK (AdGuard first; fallbacks ordered and only when enabled)"

# ---- 4. handover tasks --------------------------------------------------------------------------
H=roles/adguard/tasks/free_host_dns_port.yml
grep -q 'tailscale set --accept-dns=false' "$H" || fail "handover does not tell Tailscale to stop managing host DNS"
# Task files that site.yml includes by RAW PATH run outside any role: Ansible does not search the role's templates/ or
# files/ directory for them, so a bare file name is "not found" — which the real deploy found (check mode, 2026-09-24) and
# no render test saw. Resolve every template/copy source of such a file exactly the way Ansible would.
python3 - <<'PY' || exit 1
import os, re, sys, yaml
from jinja2 import Environment
root = os.getcwd()
site = open("site.yml").read()
files = sorted(set(re.findall(r"include_tasks:\s*(roles/\S+\.yml)", site)))
assert files, "site.yml no longer includes any task file by raw path (update this guard)"
def walk(tasks):
    for t in tasks or []:
        yield t
        for k in ("block", "rescue", "always"):
            if k in t:
                yield from walk(t[k])
bad = []
for f in files:
    d = os.path.dirname(f)
    for t in walk(yaml.safe_load(open(f))):
        for module, sub in (("ansible.builtin.template", "templates"), ("ansible.builtin.copy", "files"),
                            ("template", "templates"), ("copy", "files")):
            args = t.get(module)
            if not isinstance(args, dict) or "src" not in args:
                continue
            src = Environment().from_string(str(args["src"])).render(playbook_dir=root, role_path="")
            dirs = [os.path.join(root, d, sub), os.path.join(root, d), os.path.join(root, sub), root]
            found = os.path.isfile(src) if os.path.isabs(src) else any(os.path.isfile(os.path.join(x, src)) for x in dirs)
            if not found:
                bad.append("%s: %s src %r is not found where Ansible searches for a raw-path include" % (f, module, args["src"]))
if bad:
    print("\n".join(bad)); sys.exit(1)
print("raw-path task files (%s): every template/copy source resolves" % ", ".join(files))
PY
python3 - "$H" <<'PY' || exit 1
import sys,yaml
tasks=yaml.safe_load(open(sys.argv[1]))
def find(fragment):
    m=[t for t in tasks if fragment in t.get("name","")]
    assert len(m)==1,(fragment,len(m)); return m[0]
gate="host_dns_resolver_owner_enabled"
for frag in ("Read Tailscale's DNS management preference","Stop Tailscale managing this host's DNS","Wait until Tailscale has released"):
    w=find(frag).get("when"); w=w if isinstance(w,str) else " ".join(map(str,w or []))
    assert gate in w, f"'{frag}' must be gated on {gate} (staged rollout); when={w!r}"
rep=find("Repoint /etc/resolv.conf")
assert "adguard_resolv_conf_repoint_needed" in str(rep.get("when")), "repoint must use the decision variable"
assert rep["ansible.builtin.file"].get("force") is True, "repoint must be forced (take over Tailscale's file)"
# order: stat -> repoint -> restart, and the Tailscale release happens before the repoint
names=[t.get("name","") for t in tasks]
i_stop=names.index("Stop Tailscale managing this host's DNS"); i_wait=[i for i,n in enumerate(names) if "released /etc/resolv.conf" in n][0]
i_rep=[i for i,n in enumerate(names) if n.startswith("Repoint")][0]; i_res=[i for i,n in enumerate(names) if n.startswith("Restart systemd-resolved")][0]
i_stub=[i for i,n in enumerate(names) if "still names the disabled stub" in n][0]
assert i_stop<i_wait<i_stub<i_rep<i_res, "order must be: stop Tailscale -> wait for release -> inspect (stub check) -> repoint -> restart resolved"
print("handover gating and order OK")
PY
grep -qE "accept-dns=\{\{ 'false' if \(host_dns_resolver_owner_enabled .* else 'true' \}\}" "$TS"   || fail "tailscale up must restate --accept-dns EXPLICITLY in both switch states (else turning the switch back off can make a later re-login fail on non-default flags)"
if grep -vE '^\s*#' "$H" | grep -qiE 'sshd|ssh\.service|ssh\.socket|ufw'; then fail "DNS handover must not touch sshd or UFW"; fi
# EXECUTE the tasks' real shell commands against fixture files (the truth table above injects synthetic results,
# so without this a broken regex in the command itself would go unnoticed).
python3 - "$H" "$TMP" <<'PY' || exit 1
import subprocess,sys,yaml,os
tasks=yaml.safe_load(open(sys.argv[1])); tmp=sys.argv[2]
def cmd(prefix):
    m=[t for t in tasks if t.get("name","").startswith(prefix)]; assert len(m)==1,prefix
    return m[0]["ansible.builtin.command"]["cmd"], m[0]
fx=os.path.join(tmp,"fx"); os.makedirs(fx,exist_ok=True)
files={"stub":"# resolv.conf(5) file generated by resolvconf\nnameserver 127.0.0.53\noptions edns0\n",
       "tailscale":"# resolv.conf(5) file generated by tailscale\n# DO NOT EDIT THIS FILE BY HAND\nnameserver 100.100.100.100\n",
       "other":"nameserver 9.9.9.9\n"}
for k,v in files.items(): open(f"{fx}/{k}","w").write(v)
def run(c,path): return subprocess.run(["sh","-c",c.replace("/etc/resolv.conf",path)],capture_output=True).returncode
stub_cmd,_=cmd("Check whether /etc/resolv.conf still names")
assert run(stub_cmd,f"{fx}/stub")==0, "stub-detection must MATCH a resolv.conf naming 127.0.0.53"
assert run(stub_cmd,f"{fx}/tailscale")!=0 and run(stub_cmd,f"{fx}/other")!=0, "stub-detection must NOT match a resolv.conf that does not name the stub"
assert run(stub_cmd,f"{fx}/missing")!=0, "a missing file is 'not naming the stub' here (the decision variable handles 'missing' separately)"
wait_cmd,wait=cmd("Wait until Tailscale has released")
assert run(wait_cmd,f"{fx}/tailscale")==0, "the wait must see a Tailscale-generated file as still owned by Tailscale (rc 0)"
assert run(wait_cmd,f"{fx}/other")!=0 and run(wait_cmd,f"{fx}/stub")!=0, "the wait must see a released file (rc != 0)"
# a timeout must FAIL the play (never repoint while Tailscale may still revert the file)
assert "rc == 0" in str(wait.get("failed_when")), f"the wait must fail when Tailscale still owns the file after the retries; failed_when={wait.get('failed_when')!r}"
assert wait.get("until") and wait.get("retries",0)>=10, "the wait must retry"
print("handover shell commands executed against fixtures OK")
PY
echo "handover tasks OK (Tailscale released only under the switch; up restates it; no sshd/UFW)"

# ---- 5. documentation ---------------------------------------------------------------------------
DOC=docs/reboot-resilience.md
[[ -f "$DOC" ]] || fail "$DOC missing"
for svc in $(python3 - <<'PY'
import yaml
print(" ".join(yaml.safe_load(open("roles/docker/defaults/main.yml"))["docker_enabled_services"]))
PY
); do
  grep -qE "^\| \`$svc\` \|" "$DOC" || fail "$DOC: enabled service '$svc' has no row in the late-dependency table"
done
for pat in '≤ 60 s' 'Whole-stack bounds' 'stopped' 'hung' '≈ 0 s' '≤ ~5 s' '## Runtime-state audit' 'DOCKER-USER' 'sysctl' 'ssh.socket'; do
  grep -q -- "$pat" "$DOC" || fail "$DOC does not state: $pat"
done
echo "documentation OK (every enabled service has a dependency row; bounds and audit present)"
echo "boot ordering / host DNS guard OK"

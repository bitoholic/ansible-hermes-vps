#!/usr/bin/env bash
# Epic 21 ticket #01 — E7: is there a moment when a Docker-published port is live but the DOCKER-USER
# rule that restricts it is not, for each candidate wiring, from a COLD network state (like a reboot)?
#
# Measurement design (fixes the polling flaw found in review): an `nft monitor new rules` process is
# started BEFORE the daemon and timestamps every rule Docker or our loader adds. The events form ONE
# totally ordered stream, so "which came first" is exact — it is not inferred from polling loops whose
# latency (~30 ms per forked iptables call) is the same size as the effect being measured.
#   R = our restricted rule for the published port lands in DOCKER-USER
#   J = Docker installs the FORWARD -> DOCKER-USER jump  (a chain nothing jumps to protects nothing)
#   N = the DNAT rule for the container's published port appears (nat DOCKER)
#   F = the filter-table ACCEPT for that port appears (filter DOCKER)
#   P = min(N, F): the earliest sign the port is live (deliberately conservative)
# A wiring is SAFE in a cycle iff R precedes P AND J precedes P.  Cycles alternate A/B to remove
# ordering bias, and each scenario is repeated E7_CYCLES times.
# RUNS ONLY inside the disposable container (see guard.sh).
set -uo pipefail
# Fail CLOSED: if the guard cannot be loaded or does not pass, stop. (A bare `source` that fails would
# leave spike_guard undefined and the script would carry on — on a host that means flushing its firewall.)
[[ -f /run/.containerenv ]] || { echo "refusing: not inside a podman container" >&2; exit 2; }
[[ -r /spike/guard.sh ]] || { echo "refusing: /spike/guard.sh not readable" >&2; exit 2; }
source /spike/guard.sh || exit 2
declare -F spike_guard >/dev/null || { echo "refusing: spike_guard not defined" >&2; exit 2; }
spike_guard || exit 2
CYCLES="${E7_CYCLES:-10}"
LOG=/var/log/dockerd-e7.log; EV=/tmp/events.txt; RES=/tmp/e7-results.csv
RULES=/tmp/rules.v4
hdr() { printf '\n==== %s ====\n' "$*"; }
cat > $RULES <<'R'
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i br+ -m comment --comment "bridge return" -j RETURN
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -p tcp --dport 8082 -m comment --comment restricted-8082 -j DROP
COMMIT
R
cold_boot() {  # forget netfilter AND the bridges Docker created, as a reboot would
  for f in iptables ip6tables; do $f -F; $f -X 2>/dev/null; $f -t nat -F; $f -t nat -X 2>/dev/null; done
  ip link del docker0 2>/dev/null; for b in $(ls /sys/class/net | grep '^br-' || true); do ip link del "$b" 2>/dev/null; done
}
start_daemon() { : > $LOG; nohup dockerd --storage-driver=vfs --exec-opt native.cgroupdriver=cgroupfs --host=unix:///var/run/docker.sock >>$LOG 2>&1 & echo $! > /run/dockerd.pid; }
wait_ready() { for _ in $(seq 1 4500); do docker info >/dev/null 2>&1 && return 0; sleep 0.02; done; return 1; }
wait_port() { for _ in $(seq 1 3000); do iptables -t nat -S DOCKER 2>/dev/null | grep -q -- '--dport 8082' && return 0; sleep 0.02; done; return 1; }
stop_daemon() { local pid; pid=$(cat /run/dockerd.pid 2>/dev/null || true); [[ -n $pid ]] && kill "$pid" 2>/dev/null; for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done; rm -f /var/run/docker.pid; sleep 1; }

hdr "setup: daemon + a restart-policy container publishing 8082"
start_daemon; wait_ready || { echo "daemon not ready"; tail -20 $LOG; exit 1; }
docker pull -q docker.io/library/busybox:latest >/dev/null 2>&1
docker rm -f web >/dev/null 2>&1
docker run -d --restart unless-stopped --name web -p 8082:80 busybox sh -c 'while true; do echo ok | nc -l -p 80; done' >/dev/null \
  && echo "  container started (restart policy: unless-stopped)" || { echo "  container failed to start"; tail -5 $LOG; exit 1; }
wait_port && echo "  DNAT for 8082 present (baseline)"
echo "cycle,wiring,safe,rules_before_port,jump_before_port,lead_ms,detail" > $RES; rm -f /tmp/e7-sample.txt

analyze() {  # $1 cycle  $2 wiring label
  python3 - "$1" "$2" "$EV" >> $RES <<'PY'
import sys,re
cycle,label,path=sys.argv[1:4]
ev=[]
for i,l in enumerate(open(path,errors="replace")):
    parts=l.split(" ",1)
    if len(parts)==2 and parts[0].isdigit(): ev.append((i,int(parts[0])//1000,parts[1].strip()))  # ts in microseconds
def first(pred):
    for i,ts,t in ev:
        if pred(t): return (i,ts)
R=first(lambda t:"ip filter DOCKER-USER" in t and "8082" in t)   # (iptables-nft encodes -m comment as an opaque xt match, so match chain + port)
J=first(lambda t:re.search(r"ip filter FORWARD .*jump DOCKER-USER",t) is not None)
N=first(lambda t:"ip nat DOCKER " in t and "dnat" in t and "8082" in t)
F=first(lambda t:re.search(r"ip filter DOCKER .*dport 80 .*accept",t) is not None)
P=None
for c in (N,F):
    if c and (P is None or c[0]<P[0]): P=c
if not (R and J and P):
    print(f"{cycle},{label},NO_DATA,,,,R={R is not None} J={J is not None} N={N is not None} F={F is not None}"); sys.exit()
rules_first=R[0]<P[0]; jump_first=J[0]<P[0]
if cycle=="1":  # keep the raw ordered events for the evidence log
    with open("/tmp/e7-sample.txt","a") as out:
        out.write(f"--- cycle 1, wiring {label}: events in the order the kernel reported them (us since first) ---\n")
        base=ev[0][1] if ev else 0
        Q=first(lambda t:t.startswith("READY-RETURNED"))
        for name,x in (("R rule in DOCKER-USER",R),("J FORWARD->DOCKER-USER jump",J),("N nat DNAT",N),("F filter accept",F),("Q API answered (docker info)",Q)):
            if x: out.write(f"  #{x[0]:>4} +{x[1]-base:>8}us  {name:<30} {ev[[e[0] for e in ev].index(x[0])][2][:110]}\n")
        try:
            for l in open("/var/log/dockerd-e7.log",errors="replace"):
                if re.search(r"Loading containers|Daemon has completed initialization|API listen|Restoring containers",l): out.write("     dockerd log: "+l.strip()[:150]+"\n")
        except OSError: pass
lead=(P[1]-R[1])/1000.0   # ms; >0 rules ahead of the port, <0 port ahead of the rules
safe=rules_first and jump_first
print(f"{cycle},{label},{'yes' if safe else 'NO'},{'yes' if rules_first else 'NO'},{'yes' if jump_first else 'NO'},{lead:.1f},N={'y' if N else 'n'} F={'y' if F else 'n'}")
PY
}

run_cycle() {  # $1 cycle  $2 A|B
  local c=$1 w=$2
  stop_daemon; cold_boot; : > $EV
  ( nft monitor new rules 2>/dev/null | while IFS= read -r l; do printf '%s %s\n' "$(date +%s%N)" "$l"; done >> $EV ) 2>/dev/null &
  local mon=$!; disown "$mon" 2>/dev/null; sleep 0.4
  if [[ $w == B ]]; then iptables-restore --noflush < $RULES && ip6tables-restore --noflush < $RULES 2>/dev/null; fi   # BEFORE the daemon
  start_daemon
  wait_ready || { echo "$c,$w,NO_DATA,,,,daemon not ready" >> $RES; pkill -f "nft monitor" 2>/dev/null; return; }
  printf '%s %s\n' "$(date +%s%N)" "READY-RETURNED (docker info answered)" >> $EV
  if [[ $w == A ]]; then iptables-restore --noflush < $RULES; fi                                                          # AFTER readiness
  wait_port; sleep 0.6
  pkill -f "nft monitor" 2>/dev/null; for _ in $(seq 1 50); do pgrep -f "nft monitor" >/dev/null 2>&1 || break; sleep 0.05; done
  analyze "$c" "$w"
}

hdr "running $CYCLES cycles per wiring, alternating A/B (A = load rules right after daemon readiness; B = load before the daemon starts)"
for c in $(seq 1 "$CYCLES"); do run_cycle "$c" A; run_cycle "$c" B; done

hdr "raw per-cycle results (lead_ms > 0: rules landed that long BEFORE the port went live; < 0: the port was live that long WITHOUT its rule)"
column -s, -t $RES 2>/dev/null || cat $RES
hdr "sample: raw event order for cycle 1"; cat /tmp/e7-sample.txt 2>/dev/null
hdr "summary"
python3 - <<'PY'
import csv,statistics as st
rows=list(csv.DictReader(open("/tmp/e7-results.csv")))
for w,name in (("A","A: rules loaded AFTER daemon readiness (ExecStartPost-style)"),("B","B: rules loaded BEFORE the daemon (Before=docker.service)")):
    r=[x for x in rows if x["wiring"]==w]; ok=[x for x in r if x["safe"] in("yes","NO")]
    leads=[float(x["lead_ms"]) for x in ok if x["lead_ms"]]
    unsafe=[x for x in ok if x["safe"]=="NO"]; nodata=len(r)-len(ok)
    print(f"{name}\n  cycles with data: {len(ok)}/{len(r)}   UNSAFE cycles (port live before rule or before FORWARD jump): {len(unsafe)}")
    if leads: print(f"  lead over the port (ms): min {min(leads):.1f}  median {st.median(leads):.1f}  max {max(leads):.1f}")
PY
hdr "done"

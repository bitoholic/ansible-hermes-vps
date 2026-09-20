#!/usr/bin/env python3
"""Restart-policy guard for a RENDERED docker-compose file (epic 21 ticket #03).

Usage: assert_restart_policies.py <rendered-docker-compose.yml>

Exits 0 when every service declares a restart policy that survives a reboot or a crash
(`always` or `unless-stopped`); exits 1 and lists each offender otherwise.

It inspects the RENDERED service set — not the fragment files — so a list-driven fragment that
renders several services from one template (epic 23's exit-node pairs) is covered service by
service. There is deliberately no exemption list: a service that genuinely must not restart is
added here, with a written reason, when it first appears. `restart: "no"` therefore fails — that is
the very fault (caddy/authelia/silverbullet staying down after a reboot) this guard exists to stop.

`on-failure[:N]` is deliberately NOT accepted: it restarts a container only when it exits non-zero, and
a container that the host's shutdown stops cleanly is not reliably restarted by it after a reboot — so it
cannot be counted on for this guard's purpose (found in review).

Also invoked (as a subprocess, same command line) by tests/check-restart-policies.sh's negative fixtures.
"""
import re
import sys

import yaml

# `unless-stopped` is what this stack uses; `always` also restarts after a reboot.
ACCEPTED = re.compile(r"(always|unless-stopped)")   # matched with fullmatch(): no trailing newline slips through


def offenders(compose: dict) -> list[str]:
    services = (compose or {}).get("services") or {}
    if not services:
        return ["<no services rendered>"]
    bad = []
    for name, spec in sorted(services.items()):
        policy = (spec or {}).get("restart")
        if policy is None:
            bad.append(f"{name}: no restart policy declared")
        elif not ACCEPTED.fullmatch(str(policy)):
            bad.append(f"{name}: restart policy {policy!r} does not survive a reboot")
    return bad


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as fh:
        compose = yaml.safe_load(fh)
    bad = offenders(compose)
    if bad:
        print("FAIL: services without a reboot-surviving restart policy:", file=sys.stderr)
        for line in bad:
            print(f"  - {line}", file=sys.stderr)
        return 1
    n = len((compose or {}).get("services") or {})
    print(f"restart-policy guard OK ({n} rendered services)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

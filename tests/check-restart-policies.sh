#!/usr/bin/env bash
# Epic 21 ticket #03 guard: every RENDERED service survives a reboot or a crash.
#
# The guard itself (tests/support/assert_restart_policies.py) runs over the real rendered
# consolidated compose inside tests/test_docker_compose.yml. This script proves the guard has
# teeth, using synthetic rendered files: it must fail when a service omits a policy, when a
# policy is `no`, and — the case epic 23 depends on — when ONE fragment renders several services
# and just one of them lacks a policy; and it must pass on a fully-covered file.
# It also pins that the three services found live without a policy now declare one.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
GUARD=tests/support/assert_restart_policies.py
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== restart-policy guard (epic 21 #03) =="

expect_fail() {  # <name> <expected offender substring> ; compose on stdin
  cat > "$TMP/$1.yml"
  if python3 "$GUARD" "$TMP/$1.yml" >"$TMP/$1.out" 2>&1; then fail "guard passed on '$1' but must fail"; fi
  grep -q -- "$2" "$TMP/$1.out" || { cat "$TMP/$1.out" >&2; fail "guard failed on '$1' but did not name '$2'"; }
}

expect_fail missing 'web: no restart policy declared' <<'YML'
services:
  web:
    image: busybox
  db:
    image: busybox
    restart: unless-stopped
YML
expect_fail policy-no "web: restart policy 'no'" <<'YML'
services:
  web:
    image: busybox
    restart: "no"
YML
# one fragment, several services (epic 23's shape): only the sidecar lacks a policy
expect_fail multi-service-fragment 'pair-lon-sidecar: no restart policy declared' <<'YML'
services:
  pair-lon-tunnel:
    image: busybox
    restart: unless-stopped
  pair-lon-node:
    image: busybox
    restart: unless-stopped
  pair-lon-sidecar:
    image: busybox
YML
# on-failure only restarts after a NON-ZERO exit; a cleanly stopped container is not reliably restarted after a reboot
expect_fail policy-on-failure "web: restart policy 'on-failure:5'" <<'YML'
services:
  web:
    image: busybox
    restart: "on-failure:5"
YML
expect_fail trailing-newline "web: restart policy" <<'YML'
services:
  web:
    image: busybox
    restart: "always\n"
YML
expect_fail empty 'no services rendered' <<'YML'
version: "3"
YML

cat > "$TMP/good.yml" <<'YML'
services:
  a: {image: x, restart: unless-stopped}
  b: {image: x, restart: always}
YML
python3 "$GUARD" "$TMP/good.yml" >/dev/null || fail "guard rejected a fully covered file"
echo "guard has teeth OK (missing / 'no' / on-failure / multi-service fragment / empty all fail; covered file passes)"

# The three services found live without a policy (epic 21 spec, problem 2).
for f in caddy authelia silverbullet; do
  grep -Eq '^  restart: unless-stopped$' "roles/docker/templates/services/$f.yml.j2" \
    || fail "$f.yml.j2 must declare restart: unless-stopped (it stayed down after a reboot)"
done
echo "caddy / authelia / silverbullet restart policies OK"

# The guard must be wired into the real render test, over the rendered compose.
grep -qE '^ +cmd: .*assert_restart_policies\.py' tests/test_docker_compose.yml \
  || fail "tests/test_docker_compose.yml does not run the restart-policy guard over the rendered compose"
echo "guard wired into the rendered-compose test OK"
echo "restart-policy guard check OK"

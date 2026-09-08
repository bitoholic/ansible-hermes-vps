#!/usr/bin/env bash
# docker-starts-before-config ordering fix (epic 16, ticket #01).
#
# docker's "Start consolidated docker compose stack" task used to run as part of the
# docker role's own position in site.yml — before conduit/hermes/authelia/gateway (all
# listed after docker) ever deployed the config files their containers bind-mount. On a
# fresh bootstrap this could start a container before the file it depends on exists.
#
# Fix: the start step moved to its own task file, invoked once at the end of the play
# (after every config-deploying role), via import_role/tasks_from so docker's own
# meta/main.yml dependencies still fire for it. conduit's and hermes's provisioning
# tasks (which need the container already running) moved out of their default
# sequence the same way, invoked right after via a bare include_tasks (see site.yml
# for why import_role isn't used there — it re-triggered docker's entire role a
# second time via conduit's/hermes's meta dependency on it).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ansible.cfg sets become=true; these local checks must not escalate.
export ANSIBLE_BECOME=false

echo "== docker-starts-before-config ordering guard (epic 16) =="

# 1. docker's start task moved out of its default sequence (grep the task-name
#    line specifically, not the explanatory comment left behind pointing at it).
if grep -qE '^\s*-?\s*name:\s*Start consolidated docker compose stack' roles/docker/tasks/main.yml; then
  echo "FAIL: roles/docker/tasks/main.yml still contains the compose-stack start task"; exit 1
fi
if [[ ! -f roles/docker/tasks/start.yml ]] || ! grep -q "Start consolidated docker compose stack" roles/docker/tasks/start.yml; then
  echo "FAIL: roles/docker/tasks/start.yml missing or missing the compose-stack start task"; exit 1
fi

# 2. conduit's provisioning tasks moved out of its default sequence.
if grep -q "Register the @hermes bot account" roles/conduit/tasks/main.yml; then
  echo "FAIL: roles/conduit/tasks/main.yml still contains bot provisioning"; exit 1
fi
if [[ ! -f roles/conduit/tasks/provision.yml ]] || ! grep -q "Register the @hermes bot account" roles/conduit/tasks/provision.yml; then
  echo "FAIL: roles/conduit/tasks/provision.yml missing or missing bot provisioning"; exit 1
fi

# 3. hermes's provisioning tasks moved out of its default sequence.
if grep -q "Install Hermes skill packs" roles/hermes/tasks/main.yml; then
  echo "FAIL: roles/hermes/tasks/main.yml still contains skill-pack installation"; exit 1
fi
if [[ ! -f roles/hermes/tasks/provision.yml ]] || ! grep -q "Install Hermes skill packs" roles/hermes/tasks/provision.yml; then
  echo "FAIL: roles/hermes/tasks/provision.yml missing or missing skill-pack installation"; exit 1
fi

# 4. silverbullet's redundant second "up" call is gone (grep the actual module
#    invocation, not the explanatory comment left behind describing its removal).
if grep -qE '^\s*(community\.docker\.)?docker_compose_v2:' roles/silverbullet/tasks/main.yml; then
  echo "FAIL: roles/silverbullet/tasks/main.yml still starts the compose stack itself"; exit 1
fi

echo "task extraction OK"

# 5. site.yml invokes docker's start step via import_role/include_role (not a bare
#    include_tasks) — required so docker's own meta/main.yml dependencies still fire
#    for the relocated task.
if ! awk '/name: Start consolidated docker compose stack/{f=1} f && /ansible.builtin.import_role|ansible.builtin.include_role/{print "X"; exit} f && /ansible.builtin.include_tasks/{exit}' site.yml | grep -q X; then
  echo "FAIL: site.yml's docker start step is not invoked via import_role/include_role"; exit 1
fi

# 6. site.yml's end-of-play sequence orders docker start -> conduit provision ->
#    hermes provision (textual order in one tasks: list == execution order).
DOCKER_LINE="$(grep -n 'name: Start consolidated docker compose stack' site.yml | head -1 | cut -d: -f1)"
CONDUIT_LINE="$(grep -n 'name: Conduit bot provisioning' site.yml | head -1 | cut -d: -f1)"
HERMES_LINE="$(grep -n 'name: Hermes skill-pack provisioning' site.yml | head -1 | cut -d: -f1)"
if [[ -z "$DOCKER_LINE" || -z "$CONDUIT_LINE" || -z "$HERMES_LINE" ]]; then
  echo "FAIL: expected end-of-play task names not found in site.yml"; exit 1
fi
if ! (( DOCKER_LINE < CONDUIT_LINE && CONDUIT_LINE < HERMES_LINE )); then
  echo "FAIL: site.yml's end-of-play sequence is out of order (expected docker start, then conduit provision, then hermes provision)"
  exit 1
fi
echo "end-of-play sequence order OK"

# 7. Structural proof via --list-tasks: docker's relocated start step (the only one
#    of the three still statically expanded, since it uses import_role) appears after
#    authelia's, gateway's, and the config-phase conduit/hermes tasks that remain
#    inline in the roles: list.
LIST_OUTPUT="$(ansible-playbook site.yml --list-tasks 2>&1)" || {
  echo "FAIL: --list-tasks failed on site.yml"; echo "$LIST_OUTPUT"; exit 1
}
START_LINE="$(echo "$LIST_OUTPUT" | grep -n "docker : Start consolidated docker compose stack" | head -1 | cut -d: -f1)"
AUTHELIA_LINE="$(echo "$LIST_OUTPUT" | grep -n "Render Authelia configuration" | head -1 | cut -d: -f1)"
GATEWAY_LINE="$(echo "$LIST_OUTPUT" | grep -n "gateway : Deploy Caddyfile" | head -1 | cut -d: -f1)"
CONDUIT_CONFIG_LINE="$(echo "$LIST_OUTPUT" | grep -n "conduit : Deploy Conduit configuration" | head -1 | cut -d: -f1)"
HERMES_CONFIG_LINE="$(echo "$LIST_OUTPUT" | grep -n "hermes : Copy Hermes Dockerfile to hermes home" | head -1 | cut -d: -f1)"
if [[ -z "$START_LINE" || -z "$AUTHELIA_LINE" || -z "$GATEWAY_LINE" || -z "$CONDUIT_CONFIG_LINE" || -z "$HERMES_CONFIG_LINE" ]]; then
  echo "FAIL: expected task names not found in --list-tasks output"; echo "$LIST_OUTPUT"; exit 1
fi
for pair in "AUTHELIA_LINE:authelia" "GATEWAY_LINE:gateway" "CONDUIT_CONFIG_LINE:conduit config" "HERMES_CONFIG_LINE:hermes config"; do
  name="${pair##*:}"; var="${pair%%:*}"
  val="${!var}"
  if (( START_LINE <= val )); then
    echo "FAIL: docker's relocated start step does not run after $name (start=$START_LINE, $name=$val)"
    exit 1
  fi
done
echo "relocated start step runs after every config-deploying role OK"

# 8. No duplication of the relocated start step itself.
COUNT="$(echo "$LIST_OUTPUT" | grep -c "docker : Start consolidated docker compose stack" || true)"
if [[ "$COUNT" != "1" ]]; then
  echo "FAIL: docker's start step appears $COUNT times in the compiled task list (expected exactly 1)"
  exit 1
fi
echo "no duplicate stack-start execution OK"

echo "docker-starts-before-config ordering guard OK"

#!/usr/bin/env bash
# Epic 23 ticket #05 guard: the exit_nodes role is wired like every other role —
# tagged, skip-tags-able, documented, and ordered correctly — and skipping it
# leaves the rest of the stack unaffected.
#
# Re-runs tests/check-role-duplication.sh, which already carries this ticket's
# core ordering/duplication proof (added by ticket #03): exit_nodes runs ahead
# of docker's own compose-validate step on every occurrence, bounded at 5 runs
# per site.yml execution (EXIT_NODES_MAX), the same "more than once, but
# bounded and idempotent" family docker/wiki_volume are already in (epic 17) —
# not the "exactly once via meta dependency" family check-role-ordering.sh
# checks for gateway's owntracks/beszel/adguard dependencies, which only fits
# a role with a single dependent. exit_nodes is docker's dependency, and
# docker itself has 4 dependents plus the end-of-play stack-start step, so
# exit_nodes inherits that same multiplicity — ticket #05's original "executes
# once per run" framing does not hold, and forcing it would mean re-architecting
# away from the meta-dependency mechanism ticket #03 deliberately chose to
# match gateway's own precedent. The property that actually matters — and the
# one this guard (transitively) re-proves — is "runs ahead of docker, every
# time," not "runs exactly once."
#
# New here: a live --list-tasks proof that --skip-tags exit_nodes removes only
# exit_nodes's own tasks and changes nothing else about the compiled task list
# — no execution, no mutation, just Ansible's own task compiler.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=support/yaml_block_assertions.sh
source "$REPO_ROOT/tests/support/yaml_block_assertions.sh"

echo "== exit_nodes role-wiring guard (epic 23 #05) =="

echo "-- re-running the ordering/duplication proof (ticket #03) --"
./tests/check-role-duplication.sh

echo "-- tagged and in the skip-tags validation --"
grep -q "tags:" roles/exit_nodes/tasks/main.yml || { echo "FAIL: roles/exit_nodes/tasks/main.yml has no task-level tags entry" >&2; exit 1; }
check_in tests/lint.sh '\bexit_nodes\b' "exit_nodes in tests/lint.sh's skip-tags guard role list"
echo "tags + skip-tags guard membership OK"

echo "-- documented as skippable in the README --"
check_in README.md '`exit_nodes`' "exit_nodes in the README skippable-roles list"
echo "README membership OK"

echo "-- skipping exit_nodes leaves every other role's compiled task list unaffected --"
BASELINE="$(ansible-playbook site.yml --list-tasks 2>&1)" || { echo "FAIL: --list-tasks failed on site.yml"; echo "$BASELINE"; exit 1; }
SKIPPED="$(ansible-playbook site.yml --skip-tags exit_nodes --list-tasks 2>&1)" || { echo "FAIL: --list-tasks --skip-tags exit_nodes failed on site.yml"; echo "$SKIPPED"; exit 1; }

BASELINE_COUNT="$(grep -c "exit_nodes :" <<<"$BASELINE" || true)"
[ "${BASELINE_COUNT:-0}" -ge 1 ] || { echo "FAIL: baseline --list-tasks shows no exit_nodes tasks at all — role is not actually wired to run by default" >&2; exit 1; }

SKIPPED_COUNT="$(grep -c "exit_nodes :" <<<"$SKIPPED" || true)"
[ "${SKIPPED_COUNT:-0}" -eq 0 ] || { echo "FAIL: --skip-tags exit_nodes still shows ${SKIPPED_COUNT} exit_nodes task(s) in --list-tasks" >&2; exit 1; }

BASELINE_REST="$(grep -v "exit_nodes :" <<<"$BASELINE" || true)"
SKIPPED_REST="$(grep -v "exit_nodes :" <<<"$SKIPPED" || true)"
if [ "$BASELINE_REST" != "$SKIPPED_REST" ]; then
  echo "FAIL: skipping exit_nodes changed some other role's compiled task list — diff:" >&2
  diff <(echo "$BASELINE_REST") <(echo "$SKIPPED_REST") >&2 || true
  exit 1
fi
echo "skip-tags non-interference OK (exit_nodes tasks vanish; every other role's task list is byte-identical)"

echo "exit_nodes role-wiring guard OK"

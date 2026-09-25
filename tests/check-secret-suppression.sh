#!/usr/bin/env bash
# Epic 22 ticket #05 guard: the static secret-suppression check (scripts/check_secret_suppression.py).
#
# 1. The REAL repository passes: every task under roles/*/tasks/ that references a secrets.* value in its own
#    module arguments (including a rendered template's content and the environment: directive) carries `no_log: true`.
# 2. Negative fixtures, one per class named in the ticket: a rendered template, a command argument and a registered
#    result, each missing suppression — plus each one's suppressed counterpart must NOT be flagged (no false
#    positives), a template that dynamically includes another one is flagged conservatively, and a bare mention of
#    a secrets.* name in prose (not a real {{ }} interpolation) is correctly left alone.
#
# What this CANNOT verify: a secret that reaches an argument, a render or a registered result WITHOUT the task's own
# YAML literally interpolating secrets.* (this repo has exactly one such case, fixed by hand, not by this checker —
# see the checker's own docstring); anything outside roles/*/tasks/.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
fail() { echo "FAIL: $*" >&2; [[ -n "${OUT:-}" ]] && { echo "--- output ---" >&2; echo "$OUT" >&2; }; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is not installed" >&2; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
echo "== secret suppression guard (epic 22 #05) =="

python3 scripts/check_secret_suppression.py || fail "the real repository must pass the secret suppression guard"
echo "the real repository passes (every secret-referencing task under roles/*/tasks/ is suppressed)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/roles/leaky/tasks" "$T/roles/leaky/templates"

cat > "$T/roles/leaky/templates/leaky.j2" <<'J2'
value = {{ secrets.foo }}
J2

cat > "$T/roles/leaky/templates/dynamic.j2" <<'J2'
{% for x in enabled %}
{{ lookup('template', 'services/' + x + '.yml.j2') }}
{% endfor %}
J2

cat > "$T/roles/leaky/tasks/main.yml" <<'YML'
---
- name: Rendered template leaks a secret without suppression
  ansible.builtin.template:
    src: leaky.j2
    dest: /tmp/leaky-output

- name: Rendered template leaks a secret WITH suppression
  ansible.builtin.template:
    src: leaky.j2
    dest: /tmp/leaky-output-safe
  no_log: true

- name: Command argument leaks a secret without suppression
  ansible.builtin.command:
    cmd: "echo {{ secrets.api_token }}"

- name: Command argument leaks a secret WITH suppression
  ansible.builtin.command:
    cmd: "echo {{ secrets.api_token }}"
  no_log: true

- name: Registered result leaks a secret without suppression
  ansible.builtin.uri:
    url: "http://example.invalid/register"
    body:
      token: "{{ secrets.registration_token }}"
  register: leaky_registration_result

- name: Registered result leaks a secret WITH suppression
  ansible.builtin.uri:
    url: "http://example.invalid/register"
    body:
      token: "{{ secrets.registration_token }}"
  register: leaky_registration_result_safe
  no_log: true

- name: A dynamic sub-template lookup is flagged conservatively
  ansible.builtin.template:
    src: dynamic.j2
    dest: /tmp/dynamic-output

- name: A boolean prerequisite check is not a value emission
  ansible.builtin.assert:
    that:
      - secrets.api_token is defined
    fail_msg: "set secrets.api_token (this is prose, not an interpolation, and must not be flagged)"

- name: A block wraps a violation too
  block:
    - name: Violation nested inside a block
      ansible.builtin.command:
        cmd: "echo {{ secrets.nested_token }}"

- name: environment leaks a secret even WITH no_log (no_log cannot protect this)
  ansible.builtin.command:
    cmd: /bin/true
  environment:
    FAKE_TOKEN: "{{ secrets.env_token }}"
  no_log: true

- name: become_user leaks a secret and is not on the accepted-exceptions list
  ansible.builtin.command:
    cmd: /bin/true
  become_user: "{{ secrets.some_user }}"
  no_log: true

- name: A vars-computed intermediate still carries the original secret reference
  ansible.builtin.command:
    cmd: "echo {{ my_token }}"
  vars:
    my_token: "{{ secrets.vars_token }}"

- name: Looping directly over a secret-bearing structure
  ansible.builtin.debug:
    msg: "{{ item }}"
  loop: "{{ secrets.api_keys }}"
YML

set +e
OUT="$(python3 scripts/check_secret_suppression.py --root "$T" 2>&1)"; RC=$?
set -e
[[ $RC -eq 1 ]] || fail "the fixture tree must be flagged (rc=$RC)"

for must_flag in \
  "Rendered template leaks a secret without suppression" \
  "Command argument leaks a secret without suppression" \
  "Registered result leaks a secret without suppression" \
  "A dynamic sub-template lookup is flagged conservatively" \
  "Violation nested inside a block" \
  "environment leaks a secret even WITH no_log" \
  "become_user leaks a secret and is not on the accepted-exceptions list" \
  "A vars-computed intermediate still carries the original secret reference" \
  "Looping directly over a secret-bearing structure"; do
  grep -qF "$must_flag" <<<"$OUT" || fail "the checker did not flag: $must_flag"$'\n'"$OUT"
done
grep -qF "no_log CANNOT protect" <<<"$OUT" || fail "environment:/become_user: violations must say plainly that no_log does not fix them"

for must_not_flag in \
  "Rendered template leaks a secret WITH suppression" \
  "Command argument leaks a secret WITH suppression" \
  "Registered result leaks a secret WITH suppression" \
  "A boolean prerequisite check is not a value emission"; do
  ! grep -qF "$must_not_flag" <<<"$OUT" || fail "the checker flagged a suppressed or non-leaking task as if it were a violation: $must_not_flag"$'\n'"$OUT"
done
echo "negative fixtures: rendered template, command argument, registered result and a nested block are each flagged; their suppressed counterparts and a prose-only assert are not"

# A YAML file that doesn't parse is reported as a problem by name (rc=1), never a silent, misleading "OK" (rc=0).
mkdir -p "$T/roles/broken/tasks"
printf -- '- name: unterminated\n  ansible.builtin.command: {cmd: "echo hi"\n' > "$T/roles/broken/tasks/main.yml"
set +e
OUT="$(python3 scripts/check_secret_suppression.py --root "$T" 2>&1)"; RC=$?
set -e
[[ $RC -eq 1 ]] && grep -qi "not valid YAML" <<<"$OUT" || fail "a malformed task file must be reported, not silently ignored (rc=$RC, out=$OUT)"
rm -rf "$T/roles/broken"
echo "a malformed task file is reported by name, not silently skipped"

echo "secret suppression guard OK"

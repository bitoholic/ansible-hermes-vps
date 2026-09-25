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

cat > "$T/roles/leaky/templates/dq.j2" <<'J2'
value = {{ secrets.dq_secret }}
J2

cat > "$T/roles/leaky/templates/spacedcall.j2" <<'J2'
value = {{ secrets.spaced_call_secret }}
J2

cat > "$T/roles/leaky/templates/shortform.j2" <<'J2'
value = {{ secrets.shortform_secret }}
J2

cat > "$T/roles/leaky/templates/qalias.j2" <<'J2'
{{ q('template', 'services/' + x + '.yml.j2')[0] }}
J2

cat > "$T/roles/leaky/templates/staticinclude.j2" <<'J2'
{% include 'secret_fragment.j2' %}
J2

cat > "$T/roles/leaky/templates/secret_fragment.j2" <<'J2'
value = {{ secrets.included_secret }}
J2

cat > "$T/roles/leaky/templates/safeprose.j2" <<'J2'
This template file mentions the word "template" in prose but has no lookup or include call at all.
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

- name: Looping over a literal list of secret-interpolated strings
  ansible.builtin.debug:
    msg: "{{ item }}"
  loop:
    - "{{ secrets.list_item_one }}"
    - "{{ secrets.list_item_two }}"

- name: Whitespace around the dot or bracket must not bypass detection
  ansible.builtin.command:
    cmd: "echo {{ secrets .spaced_dot }} {{ secrets. spaced_dot2 }} {{ secrets ['spaced_bracket'] }}"

- name: A secret interpolation reflowed across multiple lines must still be caught
  ansible.builtin.command:
    cmd: |
      echo {{
        secrets.reflowed_secret
      }}

- name: A violation inside rescue must still be caught
  block:
    - name: A step that might fail
      ansible.builtin.command:
        cmd: /bin/false
  rescue:
    - name: Violation nested inside rescue
      ansible.builtin.command:
        cmd: "echo {{ secrets.rescue_token }}"

- name: A double-quoted default() must still resolve the template src
  ansible.builtin.template:
    src: "{{ which | default(\"dq.j2\") }}"
    dest: /tmp/dq-output

- name: A spaced default( call must still resolve the template src
  ansible.builtin.template:
    src: "{{ which | default ('spacedcall.j2') }}"
    dest: /tmp/spaced-output

- name: The short module name template must be followed just like the FQCN
  template:
    src: shortform.j2
    dest: /tmp/shortform-output

- name: A genuinely interpolated fail_msg must be caught, unlike bare prose
  ansible.builtin.assert:
    that:
      - secrets.interpolated_fail_check is defined
    fail_msg: "the value is {{ secrets.interpolated_fail_check }}"

- name: A non-literal no_log expression must not be accepted as suppression
  ansible.builtin.command:
    cmd: "echo {{ secrets.non_literal_no_log_token }}"
  no_log: "{{ some_flag | default(false) }}"

- name: The query alias for lookup must be caught just like lookup itself
  ansible.builtin.template:
    src: qalias.j2
    dest: /tmp/qalias-output

- name: A native include with a literal target must be followed and caught
  ansible.builtin.template:
    src: staticinclude.j2
    dest: /tmp/staticinclude-output

- name: A template that merely mentions the word template in prose must not be flagged
  ansible.builtin.template:
    src: safeprose.j2
    dest: /tmp/safeprose-output-safe

- name: A violation inside always must still be caught
  block:
    - name: A step that always runs a cleanup after
      ansible.builtin.command:
        cmd: /bin/true
  always:
    - name: Violation nested inside always
      ansible.builtin.command:
        cmd: "echo {{ secrets.always_token }}"

- name: The short assert module name must be scanned just like the FQCN
  assert:
    that:
      - secrets.short_assert_check is defined
    fail_msg: "the value is {{ secrets.short_assert_check }}"

- name: A short-name assert's that must stay exempt even when Jinja-string-wrapped, not a false positive
  assert:
    that:
      - "{{ secrets.short_assert_bare_check is defined }}"

- name: A genuinely interpolated success_msg must be caught, unlike bare prose
  ansible.builtin.assert:
    that:
      - secrets.interpolated_success_check is defined
    success_msg: "the value is {{ secrets.interpolated_success_check }}"
YML

mkdir -p "$T/roles/leaky/tasks/nested"
cat > "$T/roles/leaky/tasks/nested/sub.yml" <<'YML'
---
- name: A violation in a nested tasks subdirectory must still be caught
  ansible.builtin.command:
    cmd: "echo {{ secrets.nested_dir_token }}"
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
  "Looping directly over a secret-bearing structure" \
  "Looping over a literal list of secret-interpolated strings" \
  "Whitespace around the dot or bracket must not bypass detection" \
  "A secret interpolation reflowed across multiple lines must still be caught" \
  "Violation nested inside rescue" \
  "A double-quoted default() must still resolve the template src" \
  "A spaced default( call must still resolve the template src" \
  "The short module name template must be followed just like the FQCN" \
  "A genuinely interpolated fail_msg must be caught, unlike bare prose" \
  "A non-literal no_log expression must not be accepted as suppression" \
  "A violation in a nested tasks subdirectory must still be caught" \
  "The query alias for lookup must be caught just like lookup itself" \
  "A native include with a literal target must be followed and caught" \
  "Violation nested inside always" \
  "The short assert module name must be scanned just like the FQCN" \
  "A genuinely interpolated success_msg must be caught, unlike bare prose"; do
  grep -qF "$must_flag" <<<"$OUT" || fail "the checker did not flag: $must_flag"$'\n'"$OUT"
done
grep -qF "no_log CANNOT protect" <<<"$OUT" || fail "environment:/become_user: violations must say plainly that no_log does not fix them"

for must_not_flag in \
  "Rendered template leaks a secret WITH suppression" \
  "Command argument leaks a secret WITH suppression" \
  "Registered result leaks a secret WITH suppression" \
  "A boolean prerequisite check is not a value emission" \
  "A template that merely mentions the word template in prose must not be flagged" \
  "A short-name assert's that must stay exempt even when Jinja-string-wrapped"; do
  ! grep -qF "$must_not_flag" <<<"$OUT" || fail "the checker flagged a suppressed or non-leaking task as if it were a violation: $must_not_flag"$'\n'"$OUT"
done
echo "negative fixtures: rendered template, command argument, registered result and a nested block are each flagged; their suppressed counterparts and a prose-only assert are not"

# The become_user allowlist is keyed on (file, task name, EXACT expression) — repurposing an allowlisted task to
# carry a DIFFERENT secret through become_user, while keeping its file path and name unchanged, must still be
# flagged, not silently waved through by a looser (file, name)-only match.
mkdir -p "$T/roles/common/tasks"
cat > "$T/roles/common/tasks/main.yml" <<'YML'
---
- name: Configure global git user.name for admin user
  community.general.git_config:
    name: user.name
    value: "{{ secrets.git_username | default('') }}"
  become: true
  become_user: "{{ secrets.some_other_dangerous_secret }}"
  no_log: true
YML
set +e
OUT="$(python3 scripts/check_secret_suppression.py --root "$T" 2>&1)"; RC=$?
set -e
# Specific to THIS fixture's own file+task line, not just the generic phrase — roles/leaky's own become_user/
# environment fixtures (added above, still present in $T) already produce that same phrase regardless.
[[ $RC -eq 1 ]] && grep -qE "roles/common/tasks/main\.yml: task 'Configure global git user\.name for admin user'.*no_log CANNOT protect" <<<"$OUT" \
  || fail "repurposing an allowlisted task's become_user expression (same file, same name, different secret) must still be flagged (rc=$RC, out=$OUT)"
rm -rf "$T/roles/common"
echo "the become_user allowlist is keyed on the exact expression, not just the task's file and name"

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

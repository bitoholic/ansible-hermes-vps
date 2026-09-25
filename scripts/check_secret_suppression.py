#!/usr/bin/env python3
"""Static guard: a task cannot pass or render a secret without suppressing its output (epic 22 ticket #05).

    scripts/check_secret_suppression.py [--root DIR]      exit 0 = fine, 1 = problems (printed), 2 = cannot run

This is the second layer under output redaction (the deploy wrapper's own redaction, epic 22 #02): output
redaction protects every RUN regardless of which task leaked; this guard protects every FUTURE task by construction,
at lint time, before it ever runs.

What it asserts
  * Every task under roles/*/tasks/**/*.yml whose own module arguments (recursively) reference a `secrets.NAME` /
    `secrets[...]` value carries `no_log: true` (a literal `true` — a Jinja expression that might evaluate false is
    not accepted; the same "only a literal is safe" rule this repo already applies elsewhere, e.g. the structural
    guard's SOPS metadata checks).
  * `ansible.builtin.assert`'s own `that:` list is exempt (a boolean comparison, not a value emission) — but its
    `fail_msg`/`success_msg` are scanned like any other argument, since interpolating a value into either WOULD
    print it.
  * An `ansible.builtin.template` (or its short name, `template:`) task's `src:` is followed to the referenced .j2
    file (resolved against the role's own `templates/` directory; a `{{ ... | default('literal.j2') }}` expression
    is resolved via its literal default — single or double quotes, any whitespace around the quotes/parens all
    accepted — a `src:` this guard cannot resolve statically is not followed further) and that file's raw text is
    searched the same way. A template that itself calls `lookup('template', ...)` — or its `query()`/`q()` aliases,
    same plugin, list-returning call form — to pull in another one (this repo's own docker-compose.yml.j2, which
    assembles per-service fragments this way) is treated as needing suppression outright, without trying to resolve
    the dynamic sub-lookup — a conservative default, not a proof of absence. A native `{% include 'literal.j2' %}`
    with a literal target is instead followed and checked recursively, exactly like a task's own `src:` (a `{%
    include %}` whose target isn't a literal — a variable, a computed path — gets the same conservative treatment
    as an unresolvable `lookup()`).
  * `environment:` and `become_user:` are NEVER accepted as fixed by `no_log: true`, because they aren't: Ansible
    inlines both into the literal shell command its connection plugin prints verbatim at high verbosity (-vvv+),
    regardless of no_log — no_log only redacts a task's own arguments and registered result, not that separate
    connection-level trace. A secret reference in either is ALWAYS a hard failure here, with a message saying so,
    never a "just add no_log" one. Found the hard way, independently, twice: this ticket's own dynamic leak test
    (tests/check-playbook-secret-leak.sh, which runs at -vvv) caught roles/backup's git clone passing a token
    through `environment:`, and round 1's independent review caught roles/common's git-identity tasks passing the
    admin username through `become_user:` — both fixed at the source (a private file + a path-only reference for
    the token; accepted as an inherent, undefended limit for the username, documented at its own two call sites,
    since `become_user` must always be a literal account name for `su`/`sudo` to act on regardless of the value's
    origin — there is no file-reference equivalent for "become this user").

What this CANNOT verify
  * A secret that reaches a rendered file, a registered result or a command's arguments WITHOUT the task's own YAML
    literally referencing `secrets.*` — for example a value read back from a file that a PRIOR task wrote from a
    secret (this repo has exactly one such case, roles/owntracks/tasks/parse_htpasswd.yml's `slurp` of a
    just-generated htpasswd file, fixed by hand and not something this pattern-based guard can find on its own).
  * That `no_log: true` on a task actually suppresses everything a module might print (a module bug that ignores
    no_log is Ansible's own contract to keep, not this guard's).
  * Anything outside roles/*/tasks/ (site.yml, group_vars, other playbooks, and roles/*/handlers/ — none currently
    reference secrets.*, checked by hand, not by this guard) — the manifest and its callers are covered by other
    guards (the single-seam check in tests/lint.sh, the resolver's own test). This includes site.yml's own
    `ansible_user: "{{ secrets.admin_username }}"`, which has the identical never-fixable-by-no_log property as
    `become_user:` above (Ansible's SSH connection plugin inlines it into every task's connection trace for the
    whole play, regardless of any task's own no_log) — accepted and documented at its own call site for the same
    reason: an OS username, not a credential, with no fix available. site.yml's FIRST play (bootstrapping the admin
    account before `ansible_user` even applies) also interpolates `secrets.admin_username` (module arguments,
    unsuppressed) and `secrets.admin_ssh_public_key` (an SSH *public* key, not sensitive by definition) several
    times — outside this guard's scope, and, like `ansible_user`, not a credential leak under the same reasoning,
    but not individually enumerated at each call site the way `ansible_user` is, since none of them share
    `ansible_user`'s specific "no possible fix" property (checked by hand; found by round 5's independent review).
"""
import argparse
import glob
import os
import re
import sys

import yaml

# Only a REAL Jinja interpolation ({{ ... secrets.NAME ... }}) can ever emit a value — plain prose that merely
# names a secrets.* variable (several of this repo's own "Validate ... prerequisites" assert fail_msg strings do
# this deliberately, to tell the operator what to set) never does, and must not be flagged. `\s*` around `.`/`[`:
# real Jinja tolerates whitespace there (`secrets .x`, `secrets. x`, `secrets ['x']` all render identically to
# `secrets.x`) — an earlier version of this regex required zero whitespace and a reformatted expression could slip
# through completely undetected, including past the environment:/become_user: hard-fail check below, which shares
# this same pattern (found by round 3's independent review, verified with a live Jinja render).
SECRET_RE = re.compile(r"\{\{.*?secrets\s*(?:\.\s*[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\]).*?\}\}", re.DOTALL)
# Single or double quotes, optional whitespace before the `(` and around the literal: real Jinja/Python grammar
# accepts all of `default('x.j2')`, `default ('x.j2')`, `default("x.j2")` identically. An earlier version of this
# regex only accepted the single-quote, no-space form, so a `src:` written in any other valid style was silently
# never followed (found by round 4's independent review).
DEFAULT_JINJA_RE = re.compile(r"default\s*\(\s*['\"]([^'\"]+)['\"]\s*(?:,\s*true\s*)?\)")

# The two spellings Ansible accepts for the same module: the fully-qualified name, and its short name (resolved via
# ansible.builtin's implicit search path — extremely common in practice). An earlier version of this guard only
# recognized the FQCN, so a task written as `template:` (valid, and never exercised in this repo's own tasks today,
# but a realistic style choice) was silently never followed (found by round 4's independent review).
TEMPLATE_MODULE_NAMES = ("ansible.builtin.template", "template")

# lookup('template', ...), its `query()`/`q()` aliases (identical plugin, list-returning call form) — any quoting,
# any whitespace before the `(`. An earlier version of this guard only matched the literal substring "lookup(" (so
# `query('template', ...)`/`q('template', ...)` — both valid, both used nowhere in this repo today — silently
# defeated it entirely) (found by round 5's independent review).
LOOKUP_TEMPLATE_RE = re.compile(r"\b(?:lookup|query|q)\s*\(\s*['\"]template['\"]")
# {% include 'literal.j2' %} (any whitespace-control markers, either quote style) — a STATICALLY resolvable target,
# followed and checked exactly like a task's own src:, not treated as merely "conservative" the way the genuinely
# dynamic per-service lookup() case is.
INCLUDE_LITERAL_RE = re.compile(r"\{%[-+]?\s*include\s+['\"]([^'\"]+)['\"]")
# Any include tag at all, literal or dynamic — used to detect an include this guard could NOT resolve to a literal
# target above, which is treated the same conservative way as an unresolvable lookup('template', ...).
INCLUDE_ANY_RE = re.compile(r"\{%[-+]?\s*include\b")

# Task-level keys that can never themselves emit a value: pure control flow / metadata that Ansible never
# templates into a printed shell command or module argument. Deliberately NOT excluded (unlike an earlier version of
# this guard): `vars:` (a task can compute an intermediate name from a secret here and use only that name elsewhere
# in its args — the secret reference itself still needs to be seen) and `loop:` (a task can loop directly over a
# secret-bearing structure). `environment:` and `become_user:` are also scanned, but through their own always-fail
# check below, never the generic "add no_log" one — see the module docstring for why.
DIRECTIVE_KEYS = {
    "name", "tags", "when", "register", "changed_when", "failed_when", "notify", "listen",
    "loop_control", "become", "ignore_errors", "no_log",
    "check_mode", "delegate_to", "run_once", "any_errors_fatal", "throttle", "until",
    "retries", "delay", "block", "rescue", "always",
}

# Keys no_log cannot protect at all (see module docstring): a secret here is always a hard failure, regardless of
# no_log, and excluded from the generic scan below so it is never reported as "just add no_log" instead.
NEVER_FIXABLE_BY_NO_LOG_KEYS = {"environment", "become_user"}

# `become_user` must always be a literal account name — sudo/su act on it directly, so there is no file-reference
# equivalent the way there is for a token (which is why the environment: cases in this repo could all be redesigned
# away, but this one specific class cannot). The two tasks below use it with secrets.admin_username, the OS
# username Ansible needs to run these as: not a credential in the traditional sense (knowing it grants no
# capability by itself), and there is no fix available beyond accepting that Ansible's own connection-plugin trace
# will show it at high verbosity. Keyed on (file, task name, the EXACT become_user expression) — not just (file,
# name) — so silently repurposing an allowlisted task to pass a DIFFERENT, genuinely dangerous secret through
# become_user (same file, same name, new expression) is still a hard failure, not silently waved through. Explicit,
# narrow and justified — NOT a blanket exemption for `become_user:` elsewhere; any other task or expression is still
# a hard failure above. Fragile by design (fail-safe, not fail-silent): reformatting the expression at either call
# site (different quoting is fine — YAML normalizes that before this ever runs — but different internal whitespace,
# e.g. adding/removing spaces around the dot, is not) makes the match miss and turns back into a loud failure here;
# update this tuple to match if that ever happens deliberately.
ACCEPTED_BECOME_USER_EXCEPTIONS = {
    ("roles/common/tasks/main.yml", "Configure global git user.name for admin user", "{{ secrets.admin_username }}"),
    ("roles/common/tasks/main.yml", "Configure global git user.email for admin user", "{{ secrets.admin_username }}"),
}


def repo_root():
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.dirname(here)


def contains_secret_ref(value):
    if isinstance(value, dict):
        return any(contains_secret_ref(v) for v in value.values())
    if isinstance(value, list):
        return any(contains_secret_ref(v) for v in value)
    return bool(SECRET_RE.search(str(value)))


def module_args_to_scan(task):
    """{key: value} of everything in this task that could itself emit a value, module name included."""
    scan = {}
    for key, value in task.items():
        if key in DIRECTIVE_KEYS or key in NEVER_FIXABLE_BY_NO_LOG_KEYS:
            continue
        if key == "ansible.builtin.assert" or key == "assert":
            scan[key] = {k: v for k, v in (value or {}).items() if k != "that"}
        else:
            scan[key] = value
    return scan


def resolve_template_src(src, templates_dir):
    """A literal filename resolves directly; a `{{ ... | default('literal.j2') }}` resolves via its literal
    default; anything else (a dynamic per-item lookup this guard cannot evaluate statically) returns None."""
    if "{{" not in src:
        candidate = src
    else:
        m = DEFAULT_JINJA_RE.search(src)
        if not m:
            return None
        candidate = m.group(1)
    path = os.path.join(templates_dir, candidate)
    return path if os.path.isfile(path) else None


def template_needs_suppression(path, templates_dir, _seen=None):
    _seen = set() if _seen is None else _seen
    real_path = os.path.realpath(path)
    if real_path in _seen:
        return False   # a cycle, not a leak in itself; whatever it includes was (or will be) checked at its own site
    _seen.add(real_path)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if SECRET_RE.search(text):
        return True
    # A template that pulls in another one dynamically via lookup()/query()/q() (this repo's own docker-compose.yml.j2,
    # which assembles per-service fragments via `lookup('template', 'services/' + name + '.yml.j2')`) is treated as
    # needing suppression outright: resolving the dynamic expression statically is out of this guard's scope, and
    # silently trusting an unresolvable include would be worse than a false positive here.
    if LOOKUP_TEMPLATE_RE.search(text):
        return True
    # {% include %}: a LITERAL target is statically resolvable, so it is followed and checked exactly like a task's
    # own src: (recursively, so a chain of literal includes is fully walked). Any OTHER include tag present that
    # doesn't match the literal form (a variable, a computed path) is a dynamic include this guard cannot resolve,
    # and is treated the same conservative way as an unresolvable lookup('template', ...) above.
    for m in INCLUDE_LITERAL_RE.finditer(text):
        target = os.path.join(templates_dir, m.group(1))
        if not os.path.isfile(target) or template_needs_suppression(target, templates_dir, _seen):
            return True
    if INCLUDE_ANY_RE.search(text) and not INCLUDE_LITERAL_RE.search(text):
        return True
    return False


def walk_tasks(tasks, file_path):
    if not isinstance(tasks, list):
        return
    for task in tasks:
        if not isinstance(task, dict):
            continue
        yield task, file_path
        for section in ("block", "rescue", "always"):
            if section in task:
                yield from walk_tasks(task[section], file_path)


def check_file(path, role_dir, problems, root):
    with open(path, "r", encoding="utf-8") as fh:
        try:
            tasks = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            problems.append("%s: not valid YAML (%s)" % (path, exc))
            return
    templates_dir = os.path.join(role_dir, "templates")
    for task, file_path in walk_tasks(tasks, path):
        name = task.get("name", "(unnamed task)")
        no_log = task.get("no_log") is True

        # environment:/become_user: — never accepted as fixed by no_log; a hard failure whenever present, since
        # Ansible's own connection-plugin trace prints these regardless (see module docstring) — except the two
        # explicit, justified become_user cases in ACCEPTED_BECOME_USER_EXCEPTIONS (an OS username, not a
        # credential, with no possible fix; see that constant's own comment).
        rel_path = os.path.relpath(file_path, root)
        for key in NEVER_FIXABLE_BY_NO_LOG_KEYS:
            if key in task and contains_secret_ref(task[key]):
                if key == "become_user" and (rel_path, name, task[key]) in ACCEPTED_BECOME_USER_EXCEPTIONS:
                    continue
                problems.append(
                    "%s: task %r passes a secret through `%s:`, which no_log CANNOT protect (Ansible's connection "
                    "plugin prints it in its own trace at high verbosity regardless) — this needs a redesign, not "
                    "no_log; see this guard's own docstring" % (file_path, name, key)
                )

        scan = module_args_to_scan(task)
        leaks = contains_secret_ref(scan)
        if not leaks:
            for module_name in TEMPLATE_MODULE_NAMES:
                if module_name not in task:
                    continue
                args = task[module_name]
                src = args.get("src", "") if isinstance(args, dict) else ""
                resolved = resolve_template_src(str(src), templates_dir)
                if resolved and template_needs_suppression(resolved, templates_dir):
                    leaks = True
                break
        if leaks and not no_log:
            problems.append("%s: task %r references a secret without no_log: true" % (file_path, name))


def run(root):
    problems = []
    for role_dir in sorted(glob.glob(os.path.join(root, "roles", "*"))):
        tasks_dir = os.path.join(role_dir, "tasks")
        if not os.path.isdir(tasks_dir):
            continue
        for path in sorted(glob.glob(os.path.join(tasks_dir, "**", "*.yml"), recursive=True)):
            check_file(path, role_dir, problems, root)
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=repo_root())
    args = parser.parse_args(argv)
    try:
        problems = run(os.path.abspath(args.root))
    except OSError as exc:
        print("secret suppression guard cannot run: %s" % exc, file=sys.stderr)
        return 2
    for p in problems:
        print("FAIL: %s" % p, file=sys.stderr)
    if problems:
        return 1
    print("secret suppression guard OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

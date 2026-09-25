#!/usr/bin/env python3
"""Static guard: a task cannot pass or render a secret without suppressing its output (epic 22 ticket #05).

    scripts/check_secret_suppression.py [--root DIR]      exit 0 = fine, 1 = problems (printed), 2 = cannot run

This is the second layer under output redaction (the deploy wrapper's own redaction, epic 22 #02): output
redaction protects every RUN regardless of which task leaked; this guard protects every FUTURE task by construction,
at lint time, before it ever runs.

What it asserts
  * Every task under roles/*/tasks/**/*.yml whose own module arguments (recursively, including the `environment:`
    directive) reference a `secrets.NAME` / `secrets[...]` value carries `no_log: true` (a literal `true` — a Jinja
    expression that might evaluate false is not accepted; the same "only a literal is safe" rule this repo already
    applies elsewhere, e.g. the structural guard's SOPS metadata checks).
  * `ansible.builtin.assert`'s own `that:` list is exempt (a boolean comparison, not a value emission) — but its
    `fail_msg`/`success_msg` are scanned like any other argument, since interpolating a value into either WOULD
    print it.
  * A `template:` task's `src:` is followed to the referenced .j2 file (resolved against the role's own
    `templates/` directory; a `{{ ... | default('literal.j2') }}` expression is resolved via its literal default,
    a `src:` this guard cannot resolve statically is not followed further) and that file's raw text is searched the
    same way. A template that itself calls `lookup('template', ...)` to pull in another one (this repo's own
    docker-compose.yml.j2, which assembles per-service fragments this way) is treated as needing suppression
    outright, without trying to resolve the dynamic sub-lookup — a conservative default, not a proof of absence.

What this CANNOT verify
  * That `no_log: true` is even the right defense: a value passed via the `environment:` directive is inlined by
    Ansible into the literal shell command it runs, which its connection plugin prints verbatim at high verbosity
    (-vvv+) regardless of no_log — no_log only redacts a task's own arguments and result, not that separate
    connection-level trace. This is invisible to a static check (the YAML looks identical either way); it was found
    only by the DYNAMIC leak test (tests/check-playbook-secret-leak.sh, which runs at -vvv) catching a real instance
    of it in this repo (roles/backup's git clone), fixed by passing a file PATH through `environment:` instead of
    the value itself. A task using `environment:` with a secret should be treated as a hint to check this by hand.
  * A secret that reaches a rendered file, a registered result or a command's arguments WITHOUT the task's own YAML
    literally referencing `secrets.*` — for example a value read back from a file that a PRIOR task wrote from a
    secret (this repo has exactly one such case, roles/owntracks/tasks/parse_htpasswd.yml's `slurp` of a
    just-generated htpasswd file, fixed by hand and not something this pattern-based guard can find on its own).
  * That `no_log: true` on a task actually suppresses everything a module might print (a module bug that ignores
    no_log is Ansible's own contract to keep, not this guard's).
  * Anything outside roles/*/tasks/ (site.yml, group_vars, other playbooks) — the manifest and its callers are
    covered by other guards (the single-seam check in tests/lint.sh, the resolver's own test).
"""
import argparse
import glob
import os
import re
import sys

import yaml

# Only a REAL Jinja interpolation ({{ ... secrets.NAME ... }}) can ever emit a value — plain prose that merely
# names a secrets.* variable (several of this repo's own "Validate ... prerequisites" assert fail_msg strings do
# this deliberately, to tell the operator what to set) never does, and must not be flagged.
SECRET_RE = re.compile(r"\{\{.*?secrets(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\]).*?\}\}", re.DOTALL)
DEFAULT_JINJA_RE = re.compile(r"default\(\s*'([^']+)'\s*(?:,\s*true\s*)?\)")

# Task-level keys that are never module arguments and can never themselves emit a value the way a module's own
# arguments (including `environment:`, which a real bug in this ticket's own audit found carrying a token) can.
DIRECTIVE_KEYS = {
    "name", "tags", "when", "register", "changed_when", "failed_when", "notify", "listen",
    "loop", "loop_control", "vars", "become", "become_user", "ignore_errors", "no_log",
    "check_mode", "delegate_to", "run_once", "any_errors_fatal", "throttle", "until",
    "retries", "delay", "block", "rescue", "always", "tags",
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
        if key in DIRECTIVE_KEYS:
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


def template_needs_suppression(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if SECRET_RE.search(text):
        return True
    # A template that pulls in another one dynamically (this repo's docker-compose.yml.j2, which assembles
    # per-service fragments via `lookup('template', 'services/' + name + '.yml.j2')`) is treated as needing
    # suppression outright: resolving the dynamic expression statically is out of this guard's scope, and silently
    # trusting an unresolvable include would be worse than a false positive here.
    if "lookup(" in text and "template" in text:
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


def check_file(path, role_dir, problems):
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
        scan = module_args_to_scan(task)
        leaks = contains_secret_ref(scan)
        if not leaks and "ansible.builtin.template" in task:
            src = task["ansible.builtin.template"].get("src", "") if isinstance(task["ansible.builtin.template"], dict) else ""
            resolved = resolve_template_src(str(src), templates_dir)
            if resolved and template_needs_suppression(resolved):
                leaks = True
        if leaks and not no_log:
            problems.append("%s: task %r references a secret without no_log: true" % (file_path, name))


def run(root):
    problems = []
    for role_dir in sorted(glob.glob(os.path.join(root, "roles", "*"))):
        tasks_dir = os.path.join(role_dir, "tasks")
        if not os.path.isdir(tasks_dir):
            continue
        for path in sorted(glob.glob(os.path.join(tasks_dir, "**", "*.yml"), recursive=True)):
            check_file(path, role_dir, problems)
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

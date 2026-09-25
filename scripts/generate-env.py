#!/usr/bin/env python3
"""Generate the operator-facing env template from the secret manifest.

Single source of truth: group_vars/all/secrets.yml (secrets_manifest).
This script regenerates:
  - .env.template            (all manifest env vars + operator extras, names only)

Run with no arguments to regenerate in place (dev workflow).
Run with --check to compare against the committed file and exit non-zero on drift
(used by CI so the catalog can never silently diverge from the manifest).

Historically this also regenerated setup-env.sh, an interactive prompt script. That script is superseded by
scripts/secrets (epic 22 ticket #04) and is now a static pointer to it; nothing here writes to it any more.
"""
import os
import re
import sys
import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(REPO, "group_vars", "all", "secrets.yml")
TEMPLATE = os.path.join(REPO, ".env.template")

# Operator-facing vars that are needed but not in the manifest — the "declared extras" of the name-set rule (epic 22):
# the ONE place they are listed. The encrypted store's structural guard, the secrets helper, the deploy wrapper's
# preflight and epic 24's public-readiness audit all read this list (through scripts/hermes_secrets.py), so they can
# never disagree about which names the store may hold.
#   (name, section, secret?, required?)
# TARGET_HOST drives the deployment target (read from the store by the deploy wrapper). AUDIT_EXTRA_TERMS is the
# optional list of extra terms (hostnames, names, emails — comma-separated) that epic 24's audit also looks for; it
# may be absent from the store.
EXTRA = [
    ("TARGET_HOST", "Operator / host", False, True),
    ("AUDIT_EXTRA_TERMS", "Operator / host", False, False),
]

SECTION_ORDER = [
    "Operator / host",
    "Authelia",
    "SilverBullet",
    "Hermes / Signal",
    "Hermes credentials (wiki / default)",
    "Hermes profiles",
    "Git / GitHub",
    "Admin / host",
    "Other",
]


def section_for_key(key):
    if key.startswith("authelia_"):
        return "Authelia"
    if key.startswith("silverbullet_"):
        return "SilverBullet"
    if key.startswith("hermes_signal_"):
        return "Hermes / Signal"
    if key.startswith("hermes_default_"):
        return "Hermes credentials (wiki / default)"
    if key.startswith("git_") or key in ("github_repo_slug", "backup_github_token"):
        return "Git / GitHub"
    if key.startswith("admin_"):
        return "Admin / host"
    return "Other"


def is_secret(key):
    return bool(re.search(r"password|secret|key|token", key, re.IGNORECASE))


def load_entries():
    with open(MANIFEST, "r", encoding="utf-8") as fh:
        manifest = yaml.safe_load(fh)["secrets_manifest"]

    entries = []
    seen_env = set()

    def add(env, required, secret, section, key=None):
        if env in seen_env:
            return
        seen_env.add(env)
        entries.append(
            {
                "env": env,
                "required": required,
                "secret": secret,
                "section": section,
                "key": key,
            }
        )

    # Operator/host extras first so TARGET_HOST is listed early.
    for env, section, secret, required in EXTRA:
        add(env, required, secret, section, env)

    for key, val in manifest.items():
        env = val["env"]
        section = "Hermes profiles" if val.get("profile") else section_for_key(key)
        add(env, bool(val.get("required", False)), is_secret(key), section, key)

    return entries


def render_template(entries):
    out = [
        "# Generated .env.template - DO NOT EDIT BY HAND.",
        "# Regenerate from the manifest with: python3 scripts/generate-env.py",
        "# This file lists the environment variables read by the Ansible automation.",
        "",
    ]
    for section in SECTION_ORDER:
        sec = [e for e in entries if e["section"] == section]
        if not sec:
            continue
        out.append(f"# {section}")
        for e in sec:
            suffix = "  # required" if e["required"] else ""
            out.append(f'export {e["env"]}=""{suffix}')
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def main():
    unknown = [a for a in sys.argv[1:] if a != "--check"]
    if unknown:                                   # (an unrecognised argument such as --help must not silently regenerate files)
        sys.exit("usage: generate-env.py [--check]   (no argument: regenerate .env.template)")
    check = "--check" in sys.argv[1:]
    entries = load_entries()
    template_body = render_template(entries)

    if not check:
        with open(TEMPLATE, "w", encoding="utf-8") as fh:
            fh.write(template_body)
        print("Regenerated .env.template from the manifest.")
        return

    # --check: fail CI on drift.
    with open(TEMPLATE, "r", encoding="utf-8") as fh:
        if fh.read() != template_body:
            print("DRIFT: .env.template is out of date; run scripts/generate-env.py")
            sys.exit(1)
    print(".env.template is in sync with the manifest.")


if __name__ == "__main__":
    main()

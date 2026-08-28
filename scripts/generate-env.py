#!/usr/bin/env python3
"""Generate operator-facing env catalogs from the secret manifest.

Single source of truth: group_vars/all/secrets.yml (secrets_manifest).
This script regenerates:
  - .env.template            (all manifest env vars + operator extras)
  - setup-env.sh             (REQUIRED_VARS and SECRET_VARS arrays, between markers)

Run with no arguments to regenerate in place (dev workflow).
Run with --check to compare against the committed files and exit non-zero on drift
(used by CI so the catalogs can never silently diverge from the manifest).
"""
import os
import re
import sys
import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(REPO, "group_vars", "all", "secrets.yml")
TEMPLATE = os.path.join(REPO, ".env.template")
SETUP = os.path.join(REPO, "setup-env.sh")

# Operator-facing vars that are needed but not yet (or not ever) in the manifest.
# Per-profile Hermes keys are still consumed via group_vars hermes_profiles (ticket #06
# will fold them into the manifest); TARGET_HOST drives the ad-hoc ansible target.
EXTRA = [
    ("TARGET_HOST", "Operator / host", False),
    ("OPENROUTER_API_KEY_CODER", "Hermes profiles", True),
    ("OPENROUTER_API_KEY_INTEL", "Hermes profiles", True),
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

    # Operator/host extras first so TARGET_HOST prompts early.
    for env, section, secret in EXTRA:
        add(env, True, secret, section, env)

    for key, val in manifest.items():
        env = val["env"]
        add(env, bool(val.get("required", False)), is_secret(key), section_for_key(key), key)

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


def render_array(name, envs):
    return "\n".join('  "%s"' % env for env in envs)


def render_required_array(entries):
    return render_array("REQUIRED_VARS", [e["env"] for e in entries])


def render_secret_array(entries):
    return render_array(
        "SECRET_VARS", [e["env"] for e in entries if e["secret"]]
    )


def replace_between(content, marker, block):
    start_marker = "# >>> GENERATED_%s >>>" % marker
    end_marker = "# <<< GENERATED_%s <<<" % marker
    lines = content.split("\n")
    s = next(i for i, line in enumerate(lines) if line.strip() == start_marker)
    e = next(i for i, line in enumerate(lines) if line.strip() == end_marker)
    block_lines = block.split("\n")
    return "\n".join(lines[: s + 1] + block_lines + lines[e:])


def main():
    check = "--check" in sys.argv[1:]
    entries = load_entries()

    template_body = render_template(entries)
    required_body = render_required_array(entries)
    secret_body = render_secret_array(entries)

    if not check:
        with open(TEMPLATE, "w", encoding="utf-8") as fh:
            fh.write(template_body)
        with open(SETUP, "r", encoding="utf-8") as fh:
            setup_src = fh.read()
        setup_src = replace_between(setup_src, "REQUIRED_VARS", required_body)
        setup_src = replace_between(setup_src, "SECRET_VARS", secret_body)
        with open(SETUP, "w", encoding="utf-8") as fh:
            fh.write(setup_src)
        os.chmod(SETUP, 0o755)
        print("Regenerated .env.template and setup-env.sh from the manifest.")
        return

    # --check: fail CI on drift.
    drift = False
    with open(TEMPLATE, "r", encoding="utf-8") as fh:
        if fh.read() != template_body:
            drift = True
            print("DRIFT: .env.template is out of date; run scripts/generate-env.py")
    with open(SETUP, "r", encoding="utf-8") as fh:
        setup_src = fh.read()
    if ("# >>> GENERATED_REQUIRED_VARS >>>" not in setup_src or
            "# >>> GENERATED_SECRET_VARS >>>" not in setup_src):
        drift = True
        print("DRIFT: setup-env.sh is missing GENERATED markers; run scripts/generate-env.py")
    else:
        expected = replace_between(
            replace_between(setup_src, "REQUIRED_VARS", required_body),
            "SECRET_VARS",
            secret_body,
        )
        if expected != setup_src:
            drift = True
            print("DRIFT: setup-env.sh REQUIRED_VARS/SECRET_VARS are out of date; "
                  "run scripts/generate-env.py")
    if drift:
        sys.exit(1)
    print("env catalogs are in sync with the manifest.")


if __name__ == "__main__":
    main()

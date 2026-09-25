#!/usr/bin/env python3
"""Structural guard: a plaintext secrets file cannot be committed (epic 22 ticket #03).

    scripts/check_secrets_store.py [--root DIR]      exit 0 = fine, 1 = problems (printed), 2 = cannot run

It needs NO key: it reads only the store's visible structure (names, SOPS metadata, `ENC[...]` markers), never a value.

What it asserts
  * WHEN THE STORE MUST EXIST is DERIVED, not switched by hand: if the SOPS recipient configuration (`.sops.yaml`) is
    present, the encrypted store must be present too (deleting the store while the configuration remains fails). When
    neither is present — before the migration, and in a fresh clone of a public export, which deliberately has neither —
    only the store-independent checks below apply, and the standard lint run passes.
  * IF a store is present it must be genuinely encrypted: SOPS metadata present (`sops_version`, `sops_mac`, an age
    recipient), and EVERY value an `ENC[AES256_GCM,...]` blob (a name ending in `_unencrypted` would stay plaintext under
    SOPS's own rule — refused, as is any other cleartext value), no duplicate names, and its names satisfy the ONE name-set
    rule (scripts/hermes_secrets.py: name_set_problems — every required manifest name present; every name present a
    manifest name or a declared extra; optional entries may be absent).
  * `.sops.yaml` (when present) must scope recipients to the store's path, list at least one age recipient per rule, and
    must not weaken value encryption (`unencrypted_*`, `encrypted_*` selectors, `mac_only_encrypted`).
  * Store-independent: `.env` is untracked AND git-ignored (the tripwire); no other tracked file has the name of a
    plaintext secrets file (`.env`, `*.env` other than the store, `.env.<x>` other than the template/example); and no
    tracked file CONTENT looks like a plaintext secrets file (three or more distinct manifest names assigned to real-looking
    values). Names are reported, never values.

What this CANNOT verify: that the ciphertext decrypts (needs a key — the deploy wrapper's preflight does that), that a
value is not a weak secret, or history (epic 24 scans history).
"""
import argparse
import os
import re
import subprocess
import sys

import yaml

sys.dont_write_bytecode = True
_HERE = os.path.dirname(os.path.realpath(__file__))
sys.path[:] = [p for p in sys.path if os.path.realpath(p or os.getcwd()) != _HERE]
import importlib.util  # noqa: E402


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


hs = _load("hermes_secrets")

ENC_RE = re.compile(r"^ENC\[AES256_GCM,data:[A-Za-z0-9+/=]*,iv:[A-Za-z0-9+/=]+,tag:[A-Za-z0-9+/=]+,type:(str|int|float|bytes|bool|comment)\]$")
COMMENT_RE = re.compile(r"^#(ENC\[AES256_GCM,.*\])$")
NAME_LINE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
AGE_RECIPIENT_RE = re.compile(r"^age1[a-z0-9]{58}$")
WEAKENING_KEYS = ("unencrypted_suffix", "unencrypted_regex", "unencrypted_comment_regex", "encrypted_suffix",
                  "encrypted_regex", "encrypted_comment_regex", "mac_only_encrypted")
PLAINTEXT_FILE_THRESHOLD = 3
PLACEHOLDER_HINTS = ("%s", "$", "{{", "<", ">", "[", "...", "xxx", "changeme", "placeholder", "example", "your-", "your_",
                     "test", "fake", "dummy", "canary", "fixture", "sample")
FIXTURE_STYLE_RE = re.compile(r"^[A-Z0-9_,]+$")      # WIKI_KEY, AUTHELIA_HASH, U1,U2: a test fixture's stand-in, not a real credential
TEXT_SIZE_LIMIT = 1_000_000
SAFE_ENV_SUFFIXES = (".template", ".example", ".sample")


def git(root, *args):
    proc = subprocess.run(["git", "-C", root] + list(args), capture_output=True)
    return proc


def tracked_files(root):
    proc = git(root, "ls-files", "-z")
    if proc.returncode != 0:
        raise RuntimeError("not a git repository (the guard reads the tracked file list): %s" % root)
    return [f for f in proc.stdout.decode("utf-8", "replace").split("\0") if f]


def check_store_text(text, rel, root):
    """Problems with the structure of an encrypted dotenv store's text (names only, never values)."""
    problems, names, seen, metadata = [], [], set(), set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        if COMMENT_RE.match(line):
            continue
        m = NAME_LINE_RE.match(line)
        if not m:
            problems.append("%s:%d is not a NAME=value line (a plaintext comment or stray text?)" % (rel, number))
            continue
        name, value = m.group(1), m.group(2)
        if name.startswith("sops_"):
            metadata.add(name)
            continue
        if name in seen:
            problems.append("%s: the name %s appears more than once" % (rel, name))
        seen.add(name)
        names.append(name)
        if not ENC_RE.match(value):
            problems.append("%s: the value of %s is not encrypted (every value must be an ENC[AES256_GCM,...] blob)" % (rel, name))
    for required in ("sops_version", "sops_mac"):
        if required not in metadata:
            problems.append("%s carries no SOPS metadata (%s missing): it is not a SOPS-encrypted file" % (rel, required))
    if not any(m.startswith("sops_age__list_") and m.endswith("__map_enc") for m in metadata):
        problems.append("%s carries no age recipient entry (sops_age__list_*): nobody could decrypt it" % rel)
    missing, undeclared = hs.name_set_problems(names, root)
    if missing:
        problems.append("%s: required names missing from the store (by name): %s" % (rel, ", ".join(missing)))
    if undeclared:
        problems.append("%s: names that are neither manifest names nor declared extras (by name): %s" % (rel, ", ".join(undeclared)))
    return problems


def check_sops_config(path, store_rel):
    """Problems with .sops.yaml: recipients scoped to the store's path, at least one age recipient, no weakening."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            config = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as exc:
        return [".sops.yaml cannot be read or parsed (%s)" % type(exc).__name__]
    problems = []
    rules = config.get("creation_rules") if isinstance(config, dict) else None
    if not isinstance(rules, list) or not rules:
        return [".sops.yaml has no creation_rules"]
    scoped = False
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict):
            problems.append(".sops.yaml rule %d is not a mapping" % (i + 1))
            continue
        for key in WEAKENING_KEYS:
            if key in rule:
                problems.append(".sops.yaml rule %d sets %s, which would leave values unencrypted" % (i + 1, key))
        pattern = rule.get("path_regex")
        if not pattern:
            problems.append(".sops.yaml rule %d has no path_regex (recipients must be scoped to the store's path)" % (i + 1))
        else:
            try:
                if re.search(pattern, store_rel):
                    scoped = True
            except re.error:
                problems.append(".sops.yaml rule %d has an invalid path_regex" % (i + 1))
        recipients = []
        for group in rule.get("key_groups") or []:
            recipients += [r for r in (group.get("age") or [])]
        if isinstance(rule.get("age"), str):
            recipients += [r.strip() for r in rule["age"].split(",") if r.strip()]
        if not recipients:
            problems.append(".sops.yaml rule %d lists no age recipient" % (i + 1))
        for r in recipients:
            if not AGE_RECIPIENT_RE.match(str(r)):
                problems.append(".sops.yaml rule %d lists a recipient that is not an age public key" % (i + 1))
    if not scoped:
        problems.append(".sops.yaml has no rule whose path_regex matches the store's path %s" % store_rel)
    return problems


def looks_like_plaintext_secrets(text, names):
    """Distinct manifest/extra NAMES assigned real-looking values at the start of a line."""
    found = set()
    for line in text.splitlines():
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m or m.group(1) not in names:
            continue
        value = re.split(r"\s+#", m.group(2))[0].strip().strip("'\"").strip()       # an inline comment is not part of the value
        if not value or any(h in value.lower() for h in PLACEHOLDER_HINTS) or FIXTURE_STYLE_RE.match(value):
            continue
        found.add(m.group(1))
    return found


def run(root):
    problems = []
    tracked = tracked_files(root)
    store_rel = hs.DEFAULT_STORE_RELPATH
    store_abs = os.path.join(root, store_rel)
    config_abs = os.path.join(root, ".sops.yaml")
    config_present = os.path.isfile(config_abs)        # on disk: a file deleted from the tree (even if still in the index) is not present
    store_present = os.path.isfile(store_abs)

    if config_present and not store_present:
        problems.append("the SOPS recipient configuration is present but the encrypted store %s is missing" % store_rel)
    if store_present:
        with open(store_abs, "r", encoding="utf-8", errors="replace") as fh:
            problems += check_store_text(fh.read(), store_rel, root)
        if store_rel not in tracked and git(root, "check-ignore", "-q", store_rel).returncode == 0:
            problems.append("the encrypted store %s is git-ignored: it would never be committed" % store_rel)
        if not config_present:
            problems.append("an encrypted store is present but there is no .sops.yaml (recipients cannot be managed)")
    if config_present and os.path.isfile(config_abs):
        problems += check_sops_config(config_abs, store_rel)

    # --- store-independent checks -------------------------------------------------------------------------------
    if ".env" in tracked:
        problems.append(".env is tracked by git (a plaintext secrets file must never be committed)")
    if git(root, "check-ignore", "-q", ".env").returncode != 0:
        problems.append(".env is not git-ignored (it must stay ignored as a tripwire against committing it by accident)")

    names = hs.allowed_names(root)
    for path in tracked:
        base = os.path.basename(path)
        if path == store_rel:
            continue
        if base == ".env" and path != ".env":
            problems.append("%s: a tracked file named .env" % path)
        elif base.endswith(".env") or base == ".envrc" or (base.startswith(".env.") and not base.endswith(SAFE_ENV_SUFFIXES)):
            problems.append("%s: a tracked file with the name of a plaintext secrets file" % path)
        full = os.path.join(root, path)
        try:
            if not os.path.isfile(full) or os.path.getsize(full) > TEXT_SIZE_LIMIT:
                continue
            with open(full, "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        if b"\0" in raw:
            continue
        found = looks_like_plaintext_secrets(raw.decode("utf-8", "replace"), names)
        if len(found) >= PLAINTEXT_FILE_THRESHOLD:
            problems.append("%s: looks like a plaintext secrets file (%d manifest names assigned values, e.g. %s)"
                            % (path, len(found), ", ".join(sorted(found)[:3])))
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=hs.REPO_ROOT)
    args = parser.parse_args(argv)
    try:
        problems = run(os.path.abspath(args.root))
    except (RuntimeError, OSError, KeyError, TypeError, yaml.YAMLError) as exc:
        print("secrets store guard cannot run: %s" % (exc if isinstance(exc, RuntimeError) else type(exc).__name__), file=sys.stderr)
        return 2
    for p in problems:
        print("FAIL: %s" % p, file=sys.stderr)
    if problems:
        return 1
    print("secrets store guard OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Shared helpers for the deploy wrapper (scripts/deploy) and the secrets helper.

The encrypted store is a SOPS + age dotenv file (values encrypted, names visible). This module
knows where it lives, which names it must hold (the name-set rule), how to decrypt it *into
memory*, and how to run preflight. Nothing here ever writes a plaintext file or prints a value.

The repository root is derived from this file's own location (scripts/..), never from the
environment, so a copy of scripts/ inside a fixture tree operates on that tree only.
"""
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))

# Configuration (all optional; the defaults are this repository's own layout).
ENV_STORE = "HERMES_SECRETS_STORE"          # path of the encrypted store
ENV_KEY_FILE = "HERMES_SECRETS_KEY_FILE"    # age identity file (Tier 1: a file on this machine)
# Tier 2 (documented upgrade path, no rewrite): SOPS itself understands SOPS_AGE_KEY_CMD (a command that
# prints the identity, e.g. one that unlocks a hardware token). If it is set, the key-file checks are skipped
# because the key is not a file we can inspect.
ENV_KEY_CMD = "SOPS_AGE_KEY_CMD"

DEFAULT_STORE_RELPATH = os.path.join("secrets", "secrets.enc.env")
DEFAULT_KEY_FILE = os.path.join("~", ".config", "sops", "age", "keys.txt")

MANIFEST_RELPATH = os.path.join("group_vars", "all", "secrets.yml")
GENERATOR_RELPATH = os.path.join("scripts", "generate-env.py")
REGISTRY_RELPATH = os.path.join("scripts", "registered-scripts.conf")


# A name the store may hold is either a manifest name or a declared extra (the name-set rule). Anything else is
# refused at preflight rather than injected: a variable such as PATH, LD_PRELOAD, PYTHONPATH or ANSIBLE_* would change
# how the child runs instead of being a credential.
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class SecretsError(Exception):
    """A problem the operator must fix; the message never contains a secret value."""


def store_path(root=REPO_ROOT, environ=None):
    environ = os.environ if environ is None else environ
    override = environ.get(ENV_STORE)
    return os.path.abspath(os.path.expanduser(override)) if override else os.path.join(root, DEFAULT_STORE_RELPATH)


def key_file(environ=None):
    environ = os.environ if environ is None else environ
    return os.path.abspath(os.path.expanduser(environ.get(ENV_KEY_FILE) or DEFAULT_KEY_FILE))


# ---------------------------------------------------------------------------------------------
# The name-set rule inputs: the manifest and the generator's operator-extras list.
# ---------------------------------------------------------------------------------------------
def load_manifest(root=REPO_ROOT):
    """Return [{'env', 'key', 'required'}] for every manifest entry."""
    with open(os.path.join(root, MANIFEST_RELPATH), "r", encoding="utf-8") as fh:
        manifest = yaml.safe_load(fh)["secrets_manifest"]
    return [{"env": v["env"], "key": k, "required": bool(v.get("required", False))} for k, v in manifest.items()]


def load_extras(root=REPO_ROOT):
    """Declared extras: names the store may hold that are not manifest names, as [(env, section, secret)].

    The one place they are listed is EXTRA in scripts/generate-env.py; it is read from there so the wrapper,
    the guard, the helper and the audit can never disagree with the generator about it.
    """
    path = os.path.join(root, GENERATOR_RELPATH)
    spec = importlib.util.spec_from_file_location("hermes_generate_env", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return list(module.EXTRA)


def allowed_names(root=REPO_ROOT):
    """Every name the store may hold: all manifest names (required or not) and the declared extras."""
    return {e["env"] for e in load_manifest(root)} | {env for env, _s, _x in load_extras(root)}


def required_names(root=REPO_ROOT):
    """Names that must be present in the store: required manifest names plus required declared extras."""
    names = [e["env"] for e in load_manifest(root) if e["required"]]
    names += [env for env, _section, _secret in load_extras(root)]
    return sorted(set(names))


# ---------------------------------------------------------------------------------------------
# Decryption (in memory only)
# ---------------------------------------------------------------------------------------------
def sops_env(environ=None):
    """Environment for a sops child: tells it which age identity to use."""
    environ = dict(os.environ if environ is None else environ)
    if not environ.get(ENV_KEY_CMD):
        environ["SOPS_AGE_KEY_FILE"] = key_file(environ)
    return environ


def _sops_failure_reason(stderr):
    """A fixed-vocabulary reason for a sops failure; never any of sops' own text."""
    text = stderr.lower()
    if "mac mismatch" in text:
        return "the store's integrity check failed (edited or corrupted)"
    if "metadata not found" in text or "sops metadata" in text:
        return "the file is not a SOPS-encrypted store"
    if "no identity matched" in text or "failed to get the data key" in text or "no age identity" in text or "no key could decrypt" in text:
        return "your key is not a recipient of this store"
    if "invalid" in text or "unmarshal" in text or "parse" in text:
        return "the file is not a valid encrypted dotenv store"
    return "sops could not decrypt it"


def decrypt_store(path, environ=None):
    """Decrypt the dotenv store into a {name: value} dict held only in memory.

    JSON output is used (not dotenv) so values round-trip exactly — quoting, newlines and non-ASCII
    never pass through a dotenv parser. Nothing is written to disk by this function or by sops.
    """
    proc = subprocess.run(
        ["sops", "decrypt", "--input-type", "dotenv", "--output-type", "json", path],
        env=sops_env(environ), capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if proc.returncode != 0:
        # NEVER print sops' own text: for a file that is not a store it echoes the offending line — which can be a
        # private key or a plaintext secret (HERMES_SECRETS_STORE may point anywhere the wrapper can read). Map the
        # failure to a small fixed vocabulary instead.
        raise SecretsError("cannot decrypt the secrets store %s (%s)" % (path, _sops_failure_reason(proc.stderr or "")))
    try:
        values = json.loads(proc.stdout)
    except ValueError:
        raise SecretsError("the decrypted store %s is not a flat set of name=value pairs" % path)
    if not isinstance(values, dict) or not all(isinstance(v, str) for v in values.values()):
        raise SecretsError("the decrypted store %s is not a flat set of name=value pairs" % path)
    return values


# ---------------------------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------------------------
def preflight(root=REPO_ROOT, environ=None):
    """Check everything the wrapper needs before anything runs.

    Returns (values, problems). `problems` is a list of operator-facing messages; when it is non-empty the
    caller must exit non-zero without running anything. Messages name secrets by name only.
    """
    environ = dict(os.environ if environ is None else environ)
    problems = []

    for tool in ("sops", "age"):
        if shutil.which(tool) is None:
            problems.append("%s is not installed (see docs: onboarding a workstation)" % tool)

    store = store_path(root, environ)
    if not os.path.isfile(store):
        problems.append("the encrypted secrets store is missing: %s" % store)

    if not environ.get(ENV_KEY_CMD):
        key = key_file(environ)
        if not os.path.isfile(key):
            problems.append("your age key is missing: %s (the wrapper reads HERMES_SECRETS_KEY_FILE, not SOPS_AGE_KEY_FILE; "
                            "create it with the secrets helper; see the onboarding runbook)" % key)
        else:
            mode = stat.S_IMODE(os.stat(key).st_mode)
            if mode & 0o077:
                problems.append("your age key %s is accessible to other users (mode %o); run: chmod 600 %s" % (key, mode, key))

    if problems:
        return None, problems

    try:
        # the repository's own definition of the name-set, read BEFORE any secret is in memory
        required = required_names(root)
        allowed = allowed_names(root)
        values = decrypt_store(store, environ)
    except SecretsError as exc:
        return None, [str(exc)]
    except (OSError, ValueError, KeyError, TypeError, AttributeError, yaml.YAMLError) as exc:
        return None, ["cannot read the repository's secret manifest (%s)" % type(exc).__name__]

    undeclared = [n for n in values if not NAME_RE.fullmatch(n) or n not in allowed]
    if undeclared:
        problems.append("the store holds name(s) that are neither manifest names nor declared extras (by name): "
                        + ", ".join(sorted(undeclared)))
        return None, problems
    missing = [n for n in required if not values.get(n)]
    if missing:
        problems.append("required secrets missing from the store (by name): " + ", ".join(missing))
        return None, problems
    return values, []


# ---------------------------------------------------------------------------------------------
# Registered operator scripts (script mode)
# ---------------------------------------------------------------------------------------------
def load_registry(root=REPO_ROOT):
    """Return {name: repo-relative path} from scripts/registered-scripts.conf (the one allowlist)."""
    registry = {}
    path = os.path.join(root, REGISTRY_RELPATH)
    if not os.path.isfile(path):
        return registry
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                raise SecretsError("%s: malformed line (want 'name path'): %r" % (REGISTRY_RELPATH, raw.strip()))
            registry[parts[0]] = parts[1]
    return registry

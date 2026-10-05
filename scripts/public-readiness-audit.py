#!/usr/bin/env python3
"""Public-readiness audit (epic 24 ticket #01): is this repository safe to publish?

    scripts/deploy --script audit                              full audit: denylist + generic rules
    python3 scripts/public-readiness-audit.py --generic-only --tree-only   the lint-run scope, no key needed

Exit status: 0 = clean, 1 = finding(s) printed, 2 = cannot run (bad allowlist, not a git repository).

The full audit must run through `scripts/deploy --script audit`: script-mode children receive the
decrypted secret set in their OWN environment but never the key source or store location (see
scripts/deploy's base_environment and docstring) — by design, this script has no way to decrypt the
store itself, only to read what the wrapper already resolved. deploy's own preflight already proves
every required name is present before this script ever starts.

The denylist is derived at RUN TIME and never written down anywhere in this repository:
  * every name the name-set rule (scripts/hermes_secrets.py) allows the store to hold, for whichever
    of those names is actually present in this process's environment with a value at least
    hermes_redact.MIN_REDACT_LEN characters long (the decrypted secret set, handed to this script by
    the deploy wrapper exactly like any other registered script);
  * AUDIT_EXTRA_TERMS (the declared extra epic 22 ticket #03 reserved for this): split on commas and
    newlines, each term over the minimum length; absent is not an error;
  * the address(es) TARGET_HOST resolves to (best effort — a DNS failure is not fatal, it just means
    one fewer term).
Each term is matched literally and in every JSON-escaped/URL-encoded/repr form hermes_redact.variants()
produces for output redaction — the same forms, by construction.

Generic rules (scripts/audit_rules.py) need no key: credential shapes, tailnet CGNAT-range host
addresses (never the range's own CIDR notation), the git-crypt key-file header, and PEM/age private-key
headers. They run in BOTH modes, which is what lets --generic-only cover the standard lint run.

What is scanned: every tracked file at HEAD (working tree); every blob reachable from any ref via `git
cat-file`, read as raw bytes (binary-safe — a text-only search silently skips the git-crypt key header,
a binary blob); every commit's message, author and committer name and email, across every ref.

A finding names a RULE and a LOCATION — file:line, a historical blob's path hint and line, or a commit
and field — never the matched text. This script's own stdout/stderr, when run through the deploy
wrapper, pass through epic 22's redactor as a second guard. A minimal allowlist (audit-allowlist.yml:
path, rule, reason) can suppress a named rule at a named location; it cannot suppress a rule it does not
name (the allowlist's `rule` field is matched exactly, never a glob).
"""
import os
import sys

# Same discipline as scripts/deploy and scripts/check_secrets_store.py: this process can hold the
# decrypted secret set in memory (the full-audit mode), so scripts/ must not be an import source via
# sys.path before the sibling loader is in place.
_HERE = os.path.dirname(os.path.realpath(__file__))
sys.dont_write_bytecode = True
sys.pycache_prefix = "/nonexistent-hermes-pycache"
sys.path[:] = [p for p in sys.path if os.path.realpath(p or os.getcwd()) != _HERE]

import argparse  # noqa: E402
import fnmatch  # noqa: E402
import re  # noqa: E402
import socket  # noqa: E402
import subprocess  # noqa: E402
import threading  # noqa: E402
import importlib.util  # noqa: E402

import yaml  # noqa: E402

_boot_spec = importlib.util.spec_from_file_location("hermes_bootstrap", os.path.join(_HERE, "hermes_bootstrap.py"))
hermes_bootstrap = importlib.util.module_from_spec(_boot_spec)
sys.modules["hermes_bootstrap"] = hermes_bootstrap
_boot_spec.loader.exec_module(hermes_bootstrap)

hs = hermes_bootstrap.load_sibling("hermes_secrets")
hermes_redact = hermes_bootstrap.load_sibling("hermes_redact")
audit_rules = hermes_bootstrap.load_sibling("audit_rules")

RECORD_SEP = b"\x02HERMES-AUDIT-REC\x02"
FIELD_SEP = b"\x02HERMES-AUDIT-FLD\x02"


class AuditError(Exception):
    """A problem the operator must fix before the audit can run."""


# ---------------------------------------------------------------------------------------------
# Denylist: derived at run time, never written down.
# ---------------------------------------------------------------------------------------------
def split_extra_terms(raw):
    return [p.strip() for p in re.split(r"[,\n]+", raw) if p.strip()]


def resolve_host_addresses(host):
    """Best effort: a DNS failure (or an offline sandbox) is not fatal, it just yields no extra term."""
    addrs = set()
    try:
        for *_rest, sockaddr in socket.getaddrinfo(host, None):
            addrs.add(sockaddr[0])
    except (socket.gaierror, socket.herror, OSError):
        pass
    return sorted(addrs)


def build_denylist_terms(root, environ):
    """[(value, rule_name)] for the decrypted secret set, the extra terms and the resolved host address(es)."""
    terms = []
    for name in sorted(hs.allowed_names(root)):
        value = environ.get(name, "")
        if len(value) >= hermes_redact.MIN_REDACT_LEN:
            terms.append((value, "secret:%s" % name))
    for i, term in enumerate(split_extra_terms(environ.get("AUDIT_EXTRA_TERMS", "")), 1):
        if len(term) >= hermes_redact.MIN_REDACT_LEN:
            terms.append((term, "extra-term:%d" % i))
    host = environ.get("TARGET_HOST", "")
    if host:
        for addr in resolve_host_addresses(host):
            if len(addr) >= hermes_redact.MIN_REDACT_LEN:
                terms.append((addr, "target-host-address"))
    return terms


def build_needle_rules(terms):
    """{byte needle: rule name} covering every value literally and in every redaction-style variant."""
    needle_rule = {}
    for value, rule in terms:
        for variant in hermes_redact.variants(value):
            needle_rule.setdefault(variant, rule)
    return needle_rule


# ---------------------------------------------------------------------------------------------
# git plumbing (binary-safe: every blob is handled as raw bytes, never decoded).
# ---------------------------------------------------------------------------------------------
def _git(root, *args, input_bytes=None):
    proc = subprocess.run(["git", "-C", root] + list(args), capture_output=True, input=input_bytes)
    if proc.returncode != 0:
        raise AuditError("git %s failed: %s" % (" ".join(args), (proc.stderr or b"").decode("utf-8", "replace").strip()))
    return proc.stdout


def tracked_files(root):
    return [f for f in os.fsdecode(_git(root, "ls-files", "-z")).split("\0") if f]


def history_blob_path_hints(root):
    """{sha: a path it was once found at} for every tree/blob object reachable from any ref."""
    hints = {}
    for raw in _git(root, "rev-list", "--all", "--objects").splitlines():
        parts = raw.split(b" ", 1)
        if len(parts) != 2 or not parts[1]:
            continue   # a bare commit (or tag) line carries no path
        sha, path = parts[0].decode(), parts[1].decode("utf-8", "replace")
        hints[sha] = path
    return hints


def history_blob_shas(root):
    """{sha: path hint} restricted to objects that are actually blobs."""
    hints = history_blob_path_hints(root)
    if not hints:
        return {}
    check = _git(root, "cat-file", "--batch-check=%(objectname) %(objecttype)",
                 input_bytes=("\n".join(hints) + "\n").encode())
    blobs = {}
    for line in check.decode("ascii", "replace").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "blob":
            blobs[parts[0]] = hints.get(parts[0], "")
    return blobs


def read_blobs(root, shas):
    """Yield (sha, content bytes) for each sha via one `git cat-file --batch` process (binary-safe,
    responses arrive in request order). Writing stdin on a separate thread avoids a pipe deadlock on
    a repository with enough history that the sha list itself exceeds the pipe buffer."""
    if not shas:
        return
    proc = subprocess.Popen(["git", "-C", root, "cat-file", "--batch"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def feed():
        try:
            proc.stdin.write(("\n".join(shas) + "\n").encode())
        finally:
            proc.stdin.close()

    writer = threading.Thread(target=feed, daemon=True)
    writer.start()
    out = proc.stdout
    for sha in shas:
        header = out.readline()
        parts = header.split()
        if len(parts) < 3:
            continue   # "<sha> missing" or a malformed line: nothing to read
        size = int(parts[2])
        content = out.read(size)
        out.read(1)   # the single trailing newline git writes after every object's data
        yield sha, content
    writer.join()
    proc.wait()


def scan_tree(root, needle_rule):
    findings = []
    for path in tracked_files(root):
        full = os.path.join(root, path)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        with open(full, "rb") as fh:
            content = fh.read()
        for rule, lineno in audit_rules.scan_content(content, needle_rule):
            findings.append((rule, "tree:%s:%d" % (path, lineno)))
    return findings


def scan_history(root, needle_rule):
    findings = []
    blobs = history_blob_shas(root)
    for sha, content in read_blobs(root, list(blobs)):
        hint = blobs.get(sha) or "(no path hint)"
        for rule, lineno in audit_rules.scan_content(content, needle_rule):
            findings.append((rule, "history:%s@%s:%d" % (hint, sha[:12], lineno)))
    return findings


def scan_commit_metadata(root, needle_rule):
    fmt = FIELD_SEP.decode("latin1").join(["%H", "%an", "%ae", "%cn", "%ce", "%B"]) + RECORD_SEP.decode("latin1")
    raw = _git(root, "log", "--all", "--format=" + fmt)
    findings = []
    for record in raw.split(RECORD_SEP):
        record = record.strip(b"\n")
        if not record:
            continue
        parts = record.split(FIELD_SEP)
        if len(parts) < 6:
            continue
        sha = parts[0].decode("ascii", "replace")
        fields = [("author-name", parts[1]), ("author-email", parts[2]),
                  ("committer-name", parts[3]), ("committer-email", parts[4]),
                  ("message", FIELD_SEP.join(parts[5:]))]
        for field_name, content in fields:
            for rule, _lineno in audit_rules.scan_content(content, needle_rule):
                findings.append((rule, "commit:%s:%s" % (sha, field_name)))
    return findings


# ---------------------------------------------------------------------------------------------
# Allowlist.
# ---------------------------------------------------------------------------------------------
def load_allowlist(path):
    """[(path_glob, rule_name, reason)]. Every entry needs all three; `rule` is matched EXACTLY
    (never a glob), so an entry can never silence a rule it does not name."""
    if not os.path.isfile(path):
        return []
    with open(path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    entries = data.get("allowlist") or []
    out = []
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("path") or not entry.get("rule") or not entry.get("reason"):
            raise AuditError("%s: every allowlist entry needs path, rule and reason" % path)
        out.append((str(entry["path"]), str(entry["rule"]), str(entry["reason"])))
    return out


def is_allowed(rule, location, allowlist):
    return any(rule == allowed_rule and fnmatch.fnmatch(location, pattern) for pattern, allowed_rule, _ in allowlist)


# ---------------------------------------------------------------------------------------------
def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--generic-only", action="store_true",
                         help="run only the generic (no-secret) rules; no key or decrypted store needed")
    parser.add_argument("--tree-only", action="store_true",
                         help="scan only the working tree, not history or commit metadata (the lint-run scope: "
                              "full history is operator-run via `scripts/deploy --script audit`, not CI, because "
                              "this repository's own history already carries the dead git-crypt key on purpose "
                              "until epic 24's export — see docs/public-readiness-audit.md)")
    parser.add_argument("--root", default=hs.REPO_ROOT)
    parser.add_argument("--allowlist", default=None, help="default: <root>/audit-allowlist.yml")
    args = parser.parse_args(argv)
    root = os.path.abspath(args.root)
    allowlist_path = args.allowlist or os.path.join(root, "audit-allowlist.yml")

    needle_rule = {} if args.generic_only else build_needle_rules(build_denylist_terms(root, os.environ))

    try:
        allowlist = load_allowlist(allowlist_path)
        findings = set()
        findings |= set(scan_tree(root, needle_rule))
        if not args.tree_only:
            findings |= set(scan_history(root, needle_rule))
            findings |= set(scan_commit_metadata(root, needle_rule))
    except AuditError as exc:
        print("audit: %s" % exc, file=sys.stderr)
        return 2

    reported = sorted(f for f in findings if not is_allowed(f[0], f[1], allowlist))
    for rule, location in reported:
        print("FINDING %s %s" % (rule, location))
    suppressed = len(findings) - len(reported)
    if reported:
        print("public-readiness audit: %d finding(s), %d suppressed by the allowlist" % (len(reported), suppressed),
              file=sys.stderr)
        return 1
    print("public-readiness audit: clean (%d finding(s) suppressed by the allowlist)" % suppressed
          if suppressed else "public-readiness audit: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Public export, history-preserving (epic 24 ticket #04, reworked per the operator's own request —
see ADR-0009): turns a SCRUBBED COPY of this repository's full history — every commit, every message,
every diff — into a separate destination repository, under a commit identity the operator supplies on
every run. Never touches the source repository: git-filter-repo's --source/--target split reads one and
writes only the other.

    EXPORT_AUTHOR_NAME="..." EXPORT_AUTHOR_EMAIL="..." scripts/deploy --script export-public --dest DIR [--source DIR]

EXPORT_AUTHOR_NAME and EXPORT_AUTHOR_EMAIL are REQUIRED environment variables, not CLI flags: a real
name needs a space, and the deploy wrapper's own injection defense (SCRIPT_ARG_RE) refuses any
script-mode CLI argument containing one — by design, not a bug this script should route around. Every
other sensitive or structured input this script family takes (TARGET_HOST, AUDIT_EXTRA_TERMS, the
decrypted secrets themselves) already arrives the same way, so this follows the established pattern
rather than being an exception to it. There is no default identity: this script refuses (exit 2) if
either is unset or empty — see ADR-0009, "Commit identity: an operator input, not decided here".
--source defaults to this repository; a test points it at a fixture.

Must run through `scripts/deploy --script export-public`: scrubbing history needs the decrypted secret
set to know what to replace, exactly like `scripts/deploy --script audit` (scripts/public-readiness-
audit.py) does to know what to look for — this script refuses (exit 2) if run directly, the same way.

What one run does, in a single git-filter-repo pass over --source's full history (every ref):
  * drops secrets/secrets.enc.env, .sops.yaml, and any `*-git-crypt.key` path from EVERY commit, not
    just HEAD;
  * replaces every decrypted secret value, every AUDIT_EXTRA_TERMS entry, and TARGET_HOST's resolved
    address with a named placeholder (`<secret-name>`, `<extra-term-N>`, `<target-host-address>`), in
    file content AND commit/tag messages alike — except the handful audit-allowlist.yml already names
    as deliberately public (the operator's own chosen git identity, a stock default word) with a
    "*"-scoped entry: those are left exactly as they are, not scrubbed, by the same reasoning that
    already keeps the audit from flagging them;
  * replaces every tailnet CGNAT/ULA-range host address and every credential-shaped string the same
    way, except the functional CIDR constants and whatever specific test-fixture value audit-allowlist.
    yml already names as safe at that exact file;
  * rewrites every commit's, tag's and the one new export-notice's author AND committer to the supplied
    identity, unconditionally — nothing from the source history's own author names survives;
  * verifies the result with the real audit (scripts/public-readiness-audit.py, full history, same
    decrypted set) before ever calling the run done: a filtered export that still has an unallowlisted
    finding is refused, never left sitting in --dest as if it were clean.

Every real commit, message and diff survives untouched beyond the substitutions above. Re-running into
the same --dest re-filters --source's current (possibly longer) history from scratch; it is not an
incremental append, since git-filter-repo's own --source/--target mode already does this correctly and
idempotently — see tests/check-export-public.sh.

Exit status: 0 the export is clean and committed; 1 the filtered result still has an unallowlisted
finding (printed the same way the audit prints it — rule and location, never matched text); 2 cannot
run (bad arguments, --source is not a git repository, --dest is a symlink or resolves inside --source,
git-filter-repo is not installed, or the decrypted secret set is missing from this process).
"""
import os
import sys

# Same discipline as scripts/deploy, scripts/check_secrets_store.py and scripts/public-readiness-
# audit.py: this process holds the decrypted secret set in memory, so scripts/ must not be an import
# source via sys.path before the sibling loader is in place.
_HERE = os.path.dirname(os.path.realpath(__file__))
sys.dont_write_bytecode = True
sys.pycache_prefix = "/nonexistent-hermes-pycache"
sys.path[:] = [p for p in sys.path if os.path.realpath(p or os.getcwd()) != _HERE]

import argparse  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import importlib.util  # noqa: E402

_boot_spec = importlib.util.spec_from_file_location("hermes_bootstrap", os.path.join(_HERE, "hermes_bootstrap.py"))
hermes_bootstrap = importlib.util.module_from_spec(_boot_spec)
sys.modules["hermes_bootstrap"] = hermes_bootstrap
_boot_spec.loader.exec_module(hermes_bootstrap)

hs = hermes_bootstrap.load_sibling("hermes_secrets")
hermes_redact = hermes_bootstrap.load_sibling("hermes_redact")
audit_rules = hermes_bootstrap.load_sibling("audit_rules")
pra = hermes_bootstrap.load_sibling("public-readiness-audit")

MAX_SCRATCH_PARENT = 40   # same value as scripts/deploy's and scripts/secrets's own scratch_dir()


def scratch_dir():
    """A private (0700) directory for the scrub rules file — it holds decrypted secret VALUES as plain
    Python source, so it gets the same transient-plaintext handling as scripts/secrets's sops-edit
    scratch dir: never the world-readable default temp dir, 0700, removed as soon as filter-repo exits."""
    parent = None
    for candidate in (os.environ.get("XDG_RUNTIME_DIR"), "/dev/shm", os.environ.get("TMPDIR"), "/tmp"):
        if candidate and len(candidate) <= MAX_SCRATCH_PARENT and os.path.isdir(candidate) and os.access(candidate, os.W_OK):
            parent = candidate
            break
    path = tempfile.mkdtemp(prefix="hermes-export-scrub-", dir=parent)
    os.chmod(path, 0o700)
    return path


def fail(message):
    print("export-public: %s" % message, file=sys.stderr)
    sys.exit(2)


def _git(repo, *args, **kwargs):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, **kwargs)


def require_git_repo(path):
    result = _git(path, "rev-parse", "--is-inside-work-tree")
    if result.returncode != 0 or result.stdout.strip() != "true":
        fail("%r is not a git repository" % path)


def refuse_if_symlink(dest):
    """--dest itself must not be a symlink: git-filter-repo writes INTO --target, which would otherwise
    mean writing into whatever real directory the symlink points at — unrelated to any previous export."""
    if os.path.islink(dest):
        fail("--dest %r is a symlink; refusing (its target would be overwritten)" % dest)


def refuse_if_nested(source, dest):
    """--dest must not resolve inside --source (or equal it)."""
    source_real = os.path.realpath(source)
    dest_real = os.path.realpath(dest)
    if dest_real == source_real or dest_real.startswith(source_real + os.sep):
        fail("refusing to export into %r, which is inside --source %r" % (dest, source))


def fixture_exempt_values(root, allowlist, rule_name, pattern):
    """Every address `pattern` already matches in the CURRENT tree, at a path audit-allowlist.yml names
    as a known-safe, non-"*" exception for this exact rule (a test fixture's own functional input, not
    the operator's real address) — reusing the audit's own is_allowed() so this can never drift from
    what the audit itself already treats as safe. Scrubbing history must leave these exact values alone,
    or it would corrupt the very test fixtures that prove the range rule works."""
    exempt = set()
    for path in pra.tracked_files(root):
        full = os.path.join(root, path)
        try:
            with open(full, "rb") as fh:
                content = fh.read()
        except OSError:
            continue
        for m in pattern.finditer(content):
            location = "tree:%s:%d" % (path, content.count(b"\n", 0, m.start()) + 1)
            if pra.is_allowed(rule_name, location, allowlist):
                exempt.add(m.group(0))
    return exempt


def build_generic_rules(root, allowlist):
    """[(compiled_pattern, placeholder_bytes, exempt_set), ...] for the tailnet range rules and the
    credential-shape rules — never the git-crypt key header, a whole file removed by path instead."""
    rules = []
    baseline_exempt = {"tailnet-cgnat-address": {audit_rules.CGNAT_FUNCTIONAL_CIDR}}
    for rule_name, pattern in audit_rules.RANGE_RULES:
        exempt = set(baseline_exempt.get(rule_name, set())) | fixture_exempt_values(root, allowlist, rule_name, pattern)
        rules.append((pattern, b"<tailnet-ip>", exempt))
    for rule_name, pattern in audit_rules.CREDENTIAL_SHAPE_RULES:
        placeholder = ("<" + rule_name.replace(":", "-") + "-redacted>").encode()
        rules.append((pattern, placeholder, set()))
    return rules


def build_literal_pairs(root, environ, allowlist):
    """[(old_bytes, new_bytes), ...], longest-first. Skips any VALUE for which at least one owning
    secret: rule audit-allowlist.yml already allows at "*" scope — that is this repository's own record
    that the value is deliberately public (the operator's chosen git identity, a stock default word), so
    history-scrubbing it would destroy meaningful content for no privacy benefit, not preserve anything.

    Grouped by VALUE, not by (value, rule): more than one secret in this manifest is left at the exact
    same un-rotated default (several *_ADMIN_USERNAME entries all still say "admin"). Generating one
    substitution PER SECRET NAME for a value several secrets share would mean several (old, new) pairs
    with an IDENTICAL `old` and DIFFERENT `new` — scripts/history_scrub.py's single-pass substitution
    handles that by letting one of them win, but which one wins is incidental, and if the one that loses
    needed to stay unscrubbed (another "*"-allowlisted admin-username default), the result is still a
    corrupted, half-scrubbed value. Collapsing by value here — and skipping the value outright if ANY
    rule that shares it is "*"-allowlisted — makes the same guarantee build_needle_rules() already gives
    the audit itself (which merges findings for a shared value under whichever rule name sorts first)."""
    never_scrub = {rule for path_glob, rule, _reason in allowlist if path_glob == "*" and rule.startswith("secret:")}
    rules_by_value = {}
    for value, rule in pra.build_denylist_terms(root, environ):
        rules_by_value.setdefault(value, []).append(rule)
    pairs = []
    for value, rules in rules_by_value.items():
        if any(rule in never_scrub for rule in rules):
            continue
        placeholder = ("<" + sorted(rules)[0].lower().replace(":", "-").replace("_", "-") + ">").encode()
        for variant in hermes_redact.variants(value):
            pairs.append((variant, placeholder))
    pairs.sort(key=lambda pair: len(pair[0]), reverse=True)
    return pairs


def write_rules_module(rules_dir, literal_pairs, generic_rules):
    """A self-contained scratch module: scripts/history_scrub.py's own source (the single tested
    definition of scrub_bytes) plus this run's data. The filter-repo callbacks import ONLY from this
    scratch directory, never from scripts/ itself, so nothing here depends on the subprocess's own
    sys.path hygiene beyond what mkdtemp(0700) already gives it."""
    with open(os.path.join(_HERE, "history_scrub.py"), "r", encoding="utf-8") as fh:
        history_scrub_src = fh.read()
    raw_generic = [(pattern.pattern, placeholder, exempt) for pattern, placeholder, exempt in generic_rules]
    rules_path = os.path.join(rules_dir, "rules.py")
    with open(rules_path, "w", encoding="utf-8") as fh:
        fh.write("import re\n\n")
        fh.write(history_scrub_src)
        fh.write("\nLITERAL_PAIRS = %r\n" % literal_pairs)
        fh.write("GENERIC_RULES = [(re.compile(p), ph, ex) for p, ph, ex in %r]\n" % raw_generic)
    os.chmod(rules_path, 0o600)
    return rules_path


def run_filter_repo(source, dest, rules_dir, author_name, author_email):
    blob_body = "import sys; sys.path.insert(0, %r); import rules; blob.data = rules.scrub_bytes(blob.data, rules.LITERAL_PAIRS, rules.GENERIC_RULES)" % rules_dir
    message_body = "import sys; sys.path.insert(0, %r); import rules; return rules.scrub_bytes(message, rules.LITERAL_PAIRS, rules.GENERIC_RULES)" % rules_dir
    result = subprocess.run(
        ["git", "filter-repo",
         "--source", source, "--target", dest, "--force",
         "--invert-paths",
         "--path", "secrets/secrets.enc.env",
         "--path", ".sops.yaml",
         "--path-glob", "*-git-crypt.key",
         "--blob-callback", blob_body,
         "--message-callback", message_body,
         "--name-callback", "return %r" % author_name.encode(),
         "--email-callback", "return %r" % author_email.encode(),
         ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        fail("git filter-repo failed:\n%s" % result.stderr)


def main(argv):
    default_source = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", required=True, help="destination repository (created/overwritten with the filtered history)")
    parser.add_argument("--source", default=default_source, help="repository to export from (default: this repository)")
    args = parser.parse_args(argv)

    author_name = os.environ.get("EXPORT_AUTHOR_NAME", "")
    author_email = os.environ.get("EXPORT_AUTHOR_EMAIL", "")
    if not author_name or not author_email:
        fail("EXPORT_AUTHOR_NAME and EXPORT_AUTHOR_EMAIL must both be set (non-empty) in the environment — "
             "there is no default identity; see this script's own docstring")

    require_git_repo(args.source)
    refuse_if_symlink(args.dest)
    refuse_if_nested(args.source, args.dest)

    if shutil.which("git-filter-repo") is None:
        fail("git-filter-repo is not installed (required for the history-preserving export; "
             "`pip install git-filter-repo`, or your distribution's package)")

    missing = [n for n in hs.required_names(args.source) if not os.environ.get(n)]
    if missing:
        fail("must run through `scripts/deploy --script export-public`, which decrypts the store into "
             "this process's environment first (missing, by name): %s" % ", ".join(missing))

    source_refs_before = _git(args.source, "show-ref").stdout
    source_head_before = _git(args.source, "rev-parse", "HEAD").stdout.strip()

    allowlist = pra.load_allowlist(os.path.join(args.source, "audit-allowlist.yml"))
    literal_pairs = build_literal_pairs(args.source, os.environ, allowlist)
    generic_rules = build_generic_rules(args.source, allowlist)

    os.makedirs(args.dest, exist_ok=True)
    if not os.path.isdir(os.path.join(args.dest, ".git")):
        result = _git(args.dest, "init", "-q", "-b", "main")
        if result.returncode != 0:
            fail("`git init` failed in --dest:\n%s" % result.stderr)

    # git-filter-repo's --source, pointed directly at a non-bare working directory, follows that
    # directory's remote-advertised default branch (e.g. "main"), NOT its currently checked-out HEAD —
    # on this repository those differ (epic 24's own commits, including audit-allowlist.yml, are not on
    # main yet), so --source would silently filter a stale snapshot. A plain, single-branch `git clone`
    # of --source, by contrast, always checks out the SAME branch --source currently has checked out,
    # with no remote-tracking refs or "origin" remote left for filter-repo to also pick up and carry
    # into --dest. Clone first and point filter-repo at the clone — it is read-only input either way, so
    # this is also a second, redundant safety margin against ever touching --source itself.
    clone_dir = tempfile.mkdtemp(prefix="hermes-export-source-")
    try:
        clone_result = subprocess.run(
            ["git", "clone", "-q", "--single-branch", "--no-tags", args.source, clone_dir],
            capture_output=True, text=True,
        )
        if clone_result.returncode != 0:
            fail("cloning --source failed:\n%s" % clone_result.stderr)
        remote_result = _git(clone_dir, "remote", "remove", "origin")
        if remote_result.returncode != 0:
            fail("removing the clone's origin remote failed:\n%s" % remote_result.stderr)
        source_branch = _git(clone_dir, "branch", "--show-current").stdout.strip()
        if not source_branch:
            fail("could not determine --source's checked-out branch (detached HEAD?)")

        rules_dir = scratch_dir()
        try:
            write_rules_module(rules_dir, literal_pairs, generic_rules)
            run_filter_repo(clone_dir, args.dest, rules_dir, author_name, author_email)
        finally:
            shutil.rmtree(rules_dir, ignore_errors=True)

        if source_branch != "main":
            rename_result = _git(args.dest, "branch", "-M", source_branch, "main")
            if rename_result.returncode != 0:
                fail("renaming the exported branch %r to main failed:\n%s" % (source_branch, rename_result.stderr))

        # git-filter-repo updates --target's refs and objects but, on a --target that started as an
        # empty `git init`, does not reliably leave the working tree and index checked out to match the
        # new HEAD (observed directly: `git ls-files` empty, every tracked path showing as "deleted" in
        # `git status`, immediately after a run that otherwise succeeded) — force it, the same as a
        # fresh clone's own implicit checkout would.
        reset_result = _git(args.dest, "reset", "--hard", "HEAD")
        if reset_result.returncode != 0:
            fail("checking out --dest's filtered HEAD failed:\n%s" % reset_result.stderr)
    finally:
        shutil.rmtree(clone_dir, ignore_errors=True)

    source_refs_after = _git(args.source, "show-ref").stdout
    source_head_after = _git(args.source, "rev-parse", "HEAD").stdout.strip()
    if source_refs_before != source_refs_after or source_head_before != source_head_after:
        fail("--source changed during the export — this should be impossible; treat the result as untrusted and re-run")

    audit = subprocess.run(
        [sys.executable, os.path.join(_HERE, "public-readiness-audit.py"), "--root", args.dest],
        env=os.environ, capture_output=True, text=True,
    )
    if audit.stdout:
        print(audit.stdout, end="")
    if audit.stderr:
        print(audit.stderr, file=sys.stderr, end="")
    if audit.returncode != 0:
        fail("the filtered export still has finding(s) the allowlist doesn't cover (see above) — not "
             "exported as clean; fix the scrub rules or audit-allowlist.yml and re-run")

    dest_sha = _git(args.dest, "rev-parse", "HEAD").stdout.strip()
    commit_count = _git(args.dest, "rev-list", "--count", "HEAD").stdout.strip()
    print("export-public: %s commit(s), HEAD %s, in %s (from %s@%s) — audit clean" %
          (commit_count, dest_sha, args.dest, args.source, source_head_after))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Export a public snapshot (epic 24 ticket #04, ADR-0009): turns this repository's current, scrubbed
tree into one new commit in a SEPARATE destination repository, under a commit identity the operator
supplies on every run. It never writes to the source repository — only `git rev-parse` and `git
archive` are run against it, nothing that creates a commit, moves a ref, or touches its working tree.

    scripts/export-public.py --dest DIR --author-name NAME --author-email EMAIL [--source DIR]

--author-name and --author-email are REQUIRED: there is no default identity, and argparse refuses to
run without both (exit 2) rather than inventing or inferring one — see ADR-0009, "Commit identity: an
operator input, not decided here". --source defaults to this repository; a test points it at a fixture.

What one run does:
  * reads the exact tree of --source's HEAD (via `git archive`, never the working tree, so an
    uncommitted local change is never exported);
  * excludes exactly the paths in EXCLUDED_PATHS below — never a wildcard or a heuristic, so adding a
    new piece of secrets-tooling state later must be a deliberate edit to this list, not something
    this script discovers on its own — most importantly the encrypted secrets store itself and the SOPS
    recipient configuration (ADR-0009, "The encrypted store never goes public");
  * replaces --dest's working tree with that result (creating --dest and initializing it as a fresh
    git repository on the first run; a later run extends the same destination);
  * commits it there with GIT_AUTHOR_NAME/EMAIL and GIT_COMMITTER_NAME/EMAIL both set to the supplied
    identity — never this process's own ambient git config, so the destination never silently inherits
    whoever ran the export.

Re-running into the same --dest adds one more snapshot commit on top; it never amends or rewrites a
previous one, so the destination's own history is an honest, append-only log of every export actually
run, each independently inspectable before anything downstream (e.g. a push to a real public remote,
epic 24 ticket #05) ever happens.

Exit status: 0 the export committed; 2 cannot run — a missing required argument (argparse's own exit
2), --source is not a git repository, --dest is itself a symlink, or --dest resolves inside --source
(the last two refused because clear_destination(), below, would otherwise delete whatever the symlink
or the nested path actually points at — the source repository's own tree, or anything else real).
"""
import argparse
import os
import shutil
import subprocess
import sys
import tarfile

# Explicit and exact — never a glob or a directory prefix — so this list only ever grows by a deliberate
# edit here, not by a pattern that might also catch something it shouldn't (or miss something new).
EXCLUDED_PATHS = frozenset({
    "secrets/secrets.enc.env",
    ".sops.yaml",
})


def fail(message):
    """Every "cannot run" refusal in this script exits 2 — never argparse's own exit 2 for a missing
    required flag, and never Python's `sys.exit(str)` default of exit 1 — so the exit-status contract
    in this module's own docstring is actually true, not just documented."""
    print(f"export-public: {message}", file=sys.stderr)
    sys.exit(2)


def _git(repo, *args, **kwargs):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, **kwargs)


def require_git_repo(path):
    result = _git(path, "rev-parse", "--is-inside-work-tree")
    if result.returncode != 0 or result.stdout.strip() != "true":
        fail(f"{path!r} is not a git repository")


def refuse_if_symlink(dest):
    """--dest itself must not be a symlink: clear_destination(), below, would otherwise clear out
    whatever real directory the symlink points at — which could hold anything, with no relation to a
    previous export — rather than something this script created or owns."""
    if os.path.islink(dest):
        fail(f"--dest {dest!r} is a symlink; refusing (its target's content would be cleared)")


def refuse_if_nested(source, dest):
    """--dest must not resolve inside --source (or equal it): clearing --dest's old content, below,
    would otherwise delete the source repository's own tracked files."""
    source_real = os.path.realpath(source)
    dest_real = os.path.realpath(dest)
    if dest_real == source_real or dest_real.startswith(source_real + os.sep):
        fail(f"refusing to export into {dest!r}, which is inside --source {source!r}")


def clear_destination(dest):
    """Remove everything in dest except .git, so a path present in a previous snapshot but absent from
    this one does not linger."""
    if not os.path.isdir(dest):
        return
    for name in os.listdir(dest):
        if name == ".git":
            continue
        path = os.path.join(dest, name)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)


def extract_snapshot(source, dest):
    """Stream `git archive HEAD` from source straight into dest, skipping EXCLUDED_PATHS members as
    they're read — so an excluded file's bytes are never written to dest's filesystem at all, not even
    transiently."""
    proc = subprocess.Popen(["git", "-C", source, "archive", "HEAD"], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=proc.stdout, mode="r|*") as tar:
            for member in tar:
                if member.name in EXCLUDED_PATHS:
                    continue
                tar.extract(member, path=dest)
    finally:
        proc.stdout.close()
        if proc.wait() != 0:
            fail("`git archive HEAD` failed against --source")
    prune_empty_directories(dest)


def prune_empty_directories(dest):
    """A directory whose only tracked member was excluded still arrives as its own (empty) tar entry —
    remove it, so an excluded path leaves no trace at all, not even an empty directory."""
    for dirpath, dirnames, filenames in os.walk(dest, topdown=False):
        if dirpath == dest or ".git" in os.path.relpath(dirpath, dest).split(os.sep):
            continue
        if not dirnames and not filenames:
            os.rmdir(dirpath)


def commit_snapshot(dest, source_sha, author_name, author_email):
    result = _git(dest, "add", "-A")
    if result.returncode != 0:
        fail(f"`git add` failed in --dest:\n{result.stderr}")
    env = dict(os.environ)
    env["GIT_AUTHOR_NAME"] = author_name
    env["GIT_AUTHOR_EMAIL"] = author_email
    env["GIT_COMMITTER_NAME"] = author_name
    env["GIT_COMMITTER_EMAIL"] = author_email
    message = f"export snapshot of {source_sha}"
    result = subprocess.run(
        ["git", "-C", dest, "commit", "-q", "--allow-empty", "-m", message],
        env=env, capture_output=True, text=True,
    )
    if result.returncode != 0:
        fail(f"commit failed in --dest:\n{result.stderr}")


def main(argv):
    default_source = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", required=True, help="destination repository (created/extended)")
    parser.add_argument("--author-name", required=True, help="commit author AND committer name for this export")
    parser.add_argument("--author-email", required=True, help="commit author AND committer email for this export")
    parser.add_argument("--source", default=default_source, help="repository to export from (default: this repository)")
    args = parser.parse_args(argv)

    require_git_repo(args.source)
    refuse_if_symlink(args.dest)
    refuse_if_nested(args.source, args.dest)

    source_sha = _git(args.source, "rev-parse", "HEAD").stdout.strip()
    if not source_sha:
        fail(f"could not resolve HEAD in --source {args.source!r}")

    os.makedirs(args.dest, exist_ok=True)
    if not os.path.isdir(os.path.join(args.dest, ".git")):
        result = _git(args.dest, "init", "-q", "-b", "main")
        if result.returncode != 0:
            fail(f"`git init` failed in --dest:\n{result.stderr}")

    clear_destination(args.dest)
    extract_snapshot(args.source, args.dest)
    commit_snapshot(args.dest, source_sha, args.author_name, args.author_email)

    dest_sha = _git(args.dest, "rev-parse", "HEAD").stdout.strip()
    print(f"export-public: committed {dest_sha} to {args.dest} (from {args.source}@{source_sha})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

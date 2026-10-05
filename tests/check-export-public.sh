#!/usr/bin/env bash
# Epic 24 ticket #04 guard (reworked for the history-preserving export, ticket #05's own dry run):
# scripts/export-public.py, treated as a BLACK BOX over a throwaway fixture repository with real,
# multi-commit history and planted canaries — never the real repository. See docs/public-export.md.
#
# What this CANNOT verify: a real run against the real repository and its real secrets/history
# (operator-run, via `scripts/deploy --script export-public`, and recorded in ticket #05's own notes).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
FIX_SRC_ROOT="$ROOT_DIR"
# shellcheck source=tests/support/export-fixture.sh
source tests/support/export-fixture.sh
fail() { echo "FAIL: $*" >&2; [[ -n "${OUT:-}" ]] && { echo "--- output ---" >&2; echo "$OUT" >&2; }; exit 1; }

for tool in sops age age-keygen git-filter-repo; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is not installed (required by the epic 24 export tests; see docs onboarding)" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo "== export-public guard (epic 24 #04/#05, history-preserving) =="

make_export_fixture "$T/fixture"
SRC_REFS_BEFORE="$(git -C "$FIX_REPO" show-ref)"
SRC_HEAD_BEFORE="$(git -C "$FIX_REPO" rev-parse HEAD)"

# --- negative tests: the identity is a required ENVIRONMENT variable, not a CLI flag -----------------
unset EXPORT_AUTHOR_NAME EXPORT_AUTHOR_EMAIL || true
export_deploy --script export-public --dest "$T/dest-a"
[[ $RC -eq 2 ]] || fail "export with no identity in the environment at all must refuse with exit 2 (got $RC)"
[[ ! -e "$T/dest-a" ]] || fail "a destination was created despite the missing-identity refusal"
echo "missing identity entirely: refused (exit $RC), no destination created"

EXPORT_AUTHOR_NAME="Export Bot" export_deploy --script export-public --dest "$T/dest-b"
unset EXPORT_AUTHOR_NAME || true
[[ $RC -eq 2 ]] || fail "export with EXPORT_AUTHOR_NAME but no EXPORT_AUTHOR_EMAIL must refuse with exit 2 (got $RC)"
echo "author name without email: refused (exit $RC)"

# --- negative test: --dest is a symlink ----------------------------------------------------------------
mkdir -p "$T/elsewhere/important"
echo "pre-existing, unrelated content" > "$T/elsewhere/important/keepme.txt"
ln -s "$T/elsewhere" "$T/dest-symlink"
EXPORT_AUTHOR_NAME="Export Bot" EXPORT_AUTHOR_EMAIL="export-bot@example.invalid" \
  export_deploy --script export-public --dest "$T/dest-symlink"
[[ $RC -eq 2 ]] || fail "export with a symlinked --dest must refuse with exit 2 (got $RC)"
[[ -f "$T/elsewhere/important/keepme.txt" ]] || fail "a symlinked --dest's real target content was deleted despite the refusal"
echo "--dest is a symlink: refused (exit $RC), its target's pre-existing content is untouched"

# --- negative test: --dest nested inside --source (the fixture repo itself) ---------------------------
EXPORT_AUTHOR_NAME="Export Bot" EXPORT_AUTHOR_EMAIL="export-bot@example.invalid" \
  export_deploy --script export-public --dest "$FIX_REPO/nested-dest"
[[ $RC -eq 2 ]] || fail "export with --dest nested inside --source must refuse with exit 2 (got $RC)"
[[ ! -e "$FIX_REPO/nested-dest" ]] || fail "a nested destination was created despite the refusal"
echo "destination nested inside source: refused (exit $RC)"

# --- the real export ------------------------------------------------------------------------------------
# AUDIT_EXTRA_TERMS carries the commit-message canary: it is free text, not a secret value or a
# generic-rule shape, so nothing would ever scrub it from a commit message otherwise — this also
# exercises the real AUDIT_EXTRA_TERMS pathway (build_denylist_terms folds it in), which the export's
# own scrub shares with the audit, end to end, not just in tree content.
DEST="$T/dest"
EXPORT_AUTHOR_NAME="Export Bot" EXPORT_AUTHOR_EMAIL="export-bot@example.invalid" \
  AUDIT_EXTRA_TERMS="$EXPORT_CANARY_COMMIT_MSG" \
  export_deploy --script export-public --dest "$DEST"
[[ $RC -eq 0 ]] || fail "the real export failed (exit $RC)"
echo "$OUT" | grep -q "audit clean" || fail "the export's own success line did not report a clean audit"

# --- history is preserved, not flattened: the store-only commit (now empty) is pruned, the rest aren't --
COMMIT_COUNT="$(git -C "$DEST" rev-list --count HEAD)"
[[ "$COMMIT_COUNT" == "3" ]] || fail "expected exactly 3 commits (4 fixture commits minus the one that becomes empty once the store/key are removed), got $COMMIT_COUNT"
git -C "$DEST" log --format=%s | grep -q "^init fixture$" || fail "the init commit did not survive"
git -C "$DEST" log --format=%s | grep -q "^add canary content$" || fail "the canary-content commit did not survive"
echo "history preserved: 3 real commits survive (the secrets-only commit correctly collapses to empty and is pruned)"

# --- the fixture's real (lightweight) tag survives the export, following its rewritten commit --------
[[ "$(git -C "$DEST" tag)" == "v0.0.0-fixture" ]] || fail "the fixture's tag did not survive the export"
[[ "$(git -C "$DEST" rev-parse v0.0.0-fixture)" == "$(git -C "$DEST" rev-parse HEAD)" ]] || fail "the surviving tag points at the wrong commit"
echo "the fixture's real tag survives the export and still points at the (rewritten) commit it named"

# --- every commit's identity is rewritten, unconditionally --------------------------------------------
BAD_IDENTITY="$(git -C "$DEST" log --format='%an <%ae> / %cn <%ce>' | grep -v '^Export Bot <export-bot@example.invalid> / Export Bot <export-bot@example.invalid>$' || true)"
[[ -z "$BAD_IDENTITY" ]] || fail "not every commit carries the supplied identity: $BAD_IDENTITY"
echo "every commit's author and committer is rewritten to the supplied identity"

# --- the secrets-tooling state is absent from EVERY commit, not just HEAD -----------------------------
for path in secrets/secrets.enc.env .sops.yaml; do
  [[ ! -e "$DEST/$path" ]] || fail "$path survived at HEAD"
  git -C "$DEST" log --all --diff-filter=A -- "$path" | grep -q . && fail "$path appears somewhere in history"
done
git -C "$DEST" log --all --name-only --format= | grep -q -- '-git-crypt.key' && fail "a *-git-crypt.key path appears somewhere in history"
echo "the encrypted store, .sops.yaml and the dead git-crypt key are absent from every commit"

# --- content scrubbing, sampled directly in the final tree ---------------------------------------------
[[ ! $(grep -r "$EXPORT_CANARY_SECRET" "$DEST" 2>/dev/null) ]] || fail "the plain secret canary survived in the exported tree"
grep -q "100.64.0.0/10" "$DEST/notes/functional.txt" || fail "the functional CGNAT CIDR constant was altered"
[[ ! $(grep -r "$EXPORT_CANARY_CGNAT" "$DEST" 2>/dev/null) ]] || fail "the real-looking CGNAT host address survived unscrubbed"
grep -q "$EXPORT_CANARY_CGNAT_EXEMPT" "$DEST/notes/fixture-cgnat.txt" || fail "the allowlisted fixture CGNAT address was wrongly scrubbed"
[[ ! $(grep -r "$EXPORT_CANARY_GITHUB_TOKEN" "$DEST" 2>/dev/null) ]] || fail "the github-token-shaped canary survived unscrubbed"
[[ ! $(git -C "$DEST" log --all --format=%B | grep "$EXPORT_CANARY_COMMIT_MSG") ]] || fail "the commit-message canary survived unscrubbed"
echo "content scrubbing: the plain secret, the real CGNAT address, the credential shape and the commit-message canary are all gone; the functional CIDR and the allowlisted fixture address both survive untouched"

# --- shared-value handling: never-scrub propagates to a sharer; two scrubbed sharers collapse cleanly --
grep -q "$EXPORT_CANARY_SHARED" "$DEST/notes/shared-secret.txt" || fail "a value shared with a '*'-allowlisted secret was wrongly scrubbed"
[[ ! $(grep -r "$EXPORT_CANARY_DUP" "$DEST" 2>/dev/null) ]] || fail "a value shared by two unrelated, un-allowlisted secrets survived unscrubbed"
# Scoped to notes/ (the fixture's own planted canary content) only — $DEST/scripts/* is a verbatim
# copy of this repo's real source, which can trip this exact shape innocently (a bitshift "<<", or
# history_scrub.py's own docstring quoting the bug this check guards against as a worked example).
if grep -rlE '<[a-z-]*<' "$DEST/notes" 2>/dev/null | grep -q .; then
  fail "nested/corrupted placeholder text found (the shared-value substitution-conflict regression)"
fi
echo "shared values: a never-scrub sharer protects the value everywhere; two scrubbed sharers collapse to one consistent, non-corrupted placeholder"

# --- --source is left completely untouched -------------------------------------------------------------
[[ "$(git -C "$FIX_REPO" show-ref)" == "$SRC_REFS_BEFORE" ]] || fail "the source repository's refs changed during export"
[[ "$(git -C "$FIX_REPO" rev-parse HEAD)" == "$SRC_HEAD_BEFORE" ]] || fail "the source repository's HEAD moved during export"
git -C "$FIX_REPO" diff --quiet || fail "the source repository's working tree is dirty after export"
echo "source repository's history, refs and working tree are unchanged"

# --- a fresh clone of the export passes the standard structural guard (no store, no .sops.yaml) -------
CLONE="$T/clone"
git clone -q "$DEST" "$CLONE"
if ! python3 "$ROOT_DIR/scripts/check_secrets_store.py" --root "$CLONE" >"$T/guard.out" 2>&1; then
  cat "$T/guard.out" >&2
  fail "check_secrets_store.py failed in a fresh clone of the export"
fi
echo "a fresh clone of the export passes check_secrets_store.py"

echo "ALL OK: export-public guard"

#!/usr/bin/env bash
# Epic 24 ticket #04 guard: scripts/export-public.py, treated as a BLACK BOX over a throwaway source
# repository (never the real one) — proves the mechanism ADR-0009 describes, not the real repository's
# own content. See docs/public-readiness-audit.md's sibling doc, docs/public-export.md.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
fail() { echo "FAIL: $*" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
SRC="$T/source"
DEST="$T/dest"
EXPORT="python3 $ROOT_DIR/scripts/export-public.py"

echo "== export-public guard (epic 24 #04) =="

# --- build a throwaway source repo with a tracked secrets store + recipient config -----------------
mkdir -p "$SRC/secrets" "$SRC/notes" "$SRC/group_vars/all" "$SRC/scripts"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.name "Source Bot"
git -C "$SRC" config user.email "source-bot@example.invalid"
echo "public prose, fine to export" > "$SRC/notes/readme.txt"
cat > "$SRC/group_vars/all/secrets.yml" <<'M'
secrets_manifest:
  fix_secret:
    env: FIX_SECRET
    required: true
M
# hermes_secrets.load_extras() reads scripts/generate-env.py's own EXTRA list (never duplicated) —
# check_secrets_store.py needs this present, so the fixture's export must carry a minimal stand-in.
cat > "$SRC/scripts/generate-env.py" <<'G'
EXTRA = []
G
echo ".env" > "$SRC/.gitignore"
echo "ENC[AES256_GCM,fake,not-a-real-secret]" > "$SRC/secrets/secrets.enc.env"
cat > "$SRC/.sops.yaml" <<'S'
creation_rules:
  - path_regex: ^secrets/secrets\.enc\.env$
    key_groups:
      - age:
          - age1fakefakefakefakefakefakefakefakefakefakefakefakefakefakefakefak
S
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "init source fixture"
SRC_SHA_1="$(git -C "$SRC" rev-parse HEAD)"
SRC_REFS_BEFORE="$(git -C "$SRC" show-ref)"

# --- negative test: missing identity refuses to run --------------------------------------------------
set +e
OUT="$($EXPORT --dest "$DEST" --source "$SRC" 2>&1)"; RC=$?
set -e
[[ $RC -ne 0 ]] || fail "export ran with no --author-name/--author-email at all (must refuse)"
[[ ! -e "$DEST" ]] || fail "a destination was created despite the missing-identity refusal"
echo "missing identity entirely: refused (exit $RC), no destination created"

set +e
OUT="$($EXPORT --dest "$DEST" --source "$SRC" --author-name "Export Bot" 2>&1)"; RC=$?
set -e
[[ $RC -ne 0 ]] || fail "export ran with --author-name but no --author-email (must refuse)"
echo "author name without email: refused (exit $RC)"

# --- first real export -------------------------------------------------------------------------------
$EXPORT --dest "$DEST" --source "$SRC" --author-name "Export Bot" --author-email "export-bot@example.invalid" >/dev/null

[[ -d "$DEST/.git" ]] || fail "destination is not a git repository after export"
[[ -f "$DEST/notes/readme.txt" ]] || fail "exported tree is missing notes/readme.txt"
[[ ! -e "$DEST/secrets/secrets.enc.env" ]] || fail "the encrypted secrets store was exported — must be excluded"
[[ ! -e "$DEST/.sops.yaml" ]] || fail "the SOPS recipient configuration was exported — must be excluded"
[[ ! -d "$DEST/secrets" ]] || fail "the secrets/ directory should be empty/absent once its only file is excluded"

COMMIT_COUNT="$(git -C "$DEST" rev-list --count HEAD)"
[[ "$COMMIT_COUNT" == "1" ]] || fail "expected exactly 1 commit in the destination after one export, got $COMMIT_COUNT"

AUTHOR_LINE="$(git -C "$DEST" log -1 --format='%an <%ae> / %cn <%ce>')"
[[ "$AUTHOR_LINE" == "Export Bot <export-bot@example.invalid> / Export Bot <export-bot@example.invalid>" ]] \
  || fail "commit identity mismatch: $AUTHOR_LINE"
echo "first export: tree present, secrets store and recipient config absent, one commit, supplied identity on both author and committer"

# --- source repository must be completely untouched ---------------------------------------------------
SRC_REFS_AFTER="$(git -C "$SRC" show-ref)"
[[ "$SRC_REFS_BEFORE" == "$SRC_REFS_AFTER" ]] || fail "the source repository's refs changed during export"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$SRC_SHA_1" ]] || fail "the source repository's HEAD moved during export"
git -C "$SRC" diff --quiet || fail "the source repository's working tree is dirty after export"
echo "source repository's history, refs and working tree are unchanged"

# --- a fresh clone of the export passes the standard structural guard (no store, no .sops.yaml) ------
CLONE="$T/clone"
git clone -q "$DEST" "$CLONE"
if ! python3 "$ROOT_DIR/scripts/check_secrets_store.py" --root "$CLONE" >"$T/guard.out" 2>&1; then
  cat "$T/guard.out" >&2
  fail "check_secrets_store.py failed in a fresh clone of the export (neither store nor .sops.yaml present should be a valid, passing state)"
fi
echo "a fresh clone of the export passes check_secrets_store.py (neither-present is valid)"

# --- second export (source changed): extends with one more snapshot, never rewrites the first --------
FIRST_DEST_SHA="$(git -C "$DEST" rev-parse HEAD)"
echo "a second, later change" >> "$SRC/notes/readme.txt"
echo "a brand-new file" > "$SRC/notes/second.txt"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "second source change"

$EXPORT --dest "$DEST" --source "$SRC" --author-name "Export Bot" --author-email "export-bot@example.invalid" >/dev/null

COMMIT_COUNT="$(git -C "$DEST" rev-list --count HEAD)"
[[ "$COMMIT_COUNT" == "2" ]] || fail "expected exactly 2 commits after a second export, got $COMMIT_COUNT"
[[ "$(git -C "$DEST" rev-parse HEAD~1)" == "$FIRST_DEST_SHA" ]] || fail "the first export's commit was rewritten, not built on"
grep -q "a second, later change" "$DEST/notes/readme.txt" || fail "the second export did not pick up the source change"
[[ -f "$DEST/notes/second.txt" ]] || fail "the second export is missing the new file"
[[ ! -e "$DEST/secrets/secrets.enc.env" ]] || fail "the encrypted secrets store appeared on the second export"
echo "second export: extends the same destination with one new commit on top, picks up the source change, still excludes the store"

# --- destination may never resolve inside the source ---------------------------------------------------
set +e
OUT="$($EXPORT --dest "$SRC/nested-dest" --source "$SRC" --author-name "Export Bot" --author-email "export-bot@example.invalid" 2>&1)"; RC=$?
set -e
[[ $RC -ne 0 ]] || fail "export ran with --dest nested inside --source (must refuse)"
[[ ! -e "$SRC/nested-dest" ]] || fail "a nested destination was created despite the refusal"
echo "destination nested inside source: refused (exit $RC)"

echo "ALL OK: export-public guard"

#!/usr/bin/env bash
# Epic 24 ticket #01 guard: the public-readiness audit scanner (scripts/public-readiness-audit.py),
# treated as a BLACK BOX over a throwaway fixture repository with planted canaries — never by asserting
# on how it searches. See docs/public-readiness-audit.md.
#
# What this CANNOT verify: a real run against the real repository and its real secrets (operator-run,
# via `scripts/deploy --script audit`), or the tree/history scrub (epic 24 ticket #02).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
FIX_SRC_ROOT="$ROOT_DIR"
# shellcheck source=tests/support/audit-fixture.sh
source tests/support/audit-fixture.sh
fail() { echo "FAIL: $*" >&2; [[ -n "${OUT:-}" ]] && { echo "--- output ---" >&2; echo "$OUT" >&2; }; exit 1; }

for tool in sops age age-keygen; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is not installed (required by the epic 24 tests; see docs onboarding)" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo "== public-readiness audit guard (epic 24 #01) =="

# --- the dirty fixture: every rule must fire, nothing it finds leaks the matched text -------------------
make_audit_fixture "$T/dirty" dirty
audit_deploy --script audit
[[ $RC -eq 1 ]] || fail "the dirty fixture must exit 1 (got $RC)"

expect() { grep -qE -- "$1" <<<"$OUT" || fail "expected finding not reported: $1"; }

expect '^FINDING secret:FIX_AUDIT_SECRET tree:notes/tree-secret\.txt:1$'
expect '^FINDING extra-term:1 tree:notes/extra-term\.txt:1$'
expect '^FINDING target-host-address tree:notes/host-address\.txt:1$'
expect '^FINDING secret:FIX_AUDIT_SECRET tree:notes/encoded\.txt:1$'   # JSON-escaped form
expect '^FINDING secret:FIX_AUDIT_SECRET tree:notes/encoded\.txt:2$'   # URL-encoded form
expect '^FINDING credential-shape:github-token tree:notes/generic-shapes\.txt:1$'
expect '^FINDING age-secret-key tree:notes/generic-shapes\.txt:2$'
expect '^FINDING private-key-header tree:notes/generic-shapes\.txt:3$'
expect '^FINDING credential-shape:tailscale-authkey tree:notes/generic-shapes\.txt:4$'
expect '^FINDING tailnet-cgnat-address tree:notes/cgnat\.txt:1$'
expect '^FINDING tailnet-ula-address tree:notes/ula\.txt:1$'
expect '^FINDING extra-term:2 history:notes/history-only-secret\.txt@[0-9a-f]+:1$'          # history-only (removed from the tree)
expect '^FINDING git-crypt-key-header history:notes/old\.key@[0-9a-f]+:1$'                  # side branch, never merged, binary blob
expect '^FINDING extra-term:3 commit:[0-9a-f]+:message$'                                     # commit message
expect '^FINDING extra-term:4 commit:[0-9a-f]+:author-name$'
expect '^FINDING extra-term:5 commit:[0-9a-f]+:author-email$'
expect '^FINDING extra-term:6 commit:[0-9a-f]+:committer-name$'
expect '^FINDING extra-term:7 commit:[0-9a-f]+:committer-email$'
echo "every planted canary found: tree, history (including a side branch never merged to main), commit message, author/committer metadata, JSON/URL-encoded forms, and every generic rule"

# the functional CIDRs must never be flagged
if grep -q 'notes/cgnat-functional' <<<"$OUT"; then
  fail "the tailnet subnet's own CIDR notation (100.64.0.0/10) was flagged; it is a functional value, not a host address"
fi
if grep -q 'notes/ula-functional' <<<"$OUT"; then
  fail "the tailnet ULA prefix's own CIDR notation (fd7a:115c:a1e0::/48) was flagged; it is a functional value, not a host address"
fi
echo "the CGNAT range's and the ULA prefix's own CIDR notation are not flagged (negative case)"

# the report must never contain the matched text itself
for canary in "$AUDIT_CANARY_SECRET" "$AUDIT_CANARY_EXTRA" "$AUDIT_CANARY_HISTORY" "$AUDIT_CANARY_COMMIT_MSG" \
              "$AUDIT_CANARY_AUTHOR_NAME" "$AUDIT_CANARY_AUTHOR_EMAIL" "$AUDIT_CANARY_COMMITTER_NAME" "$AUDIT_CANARY_COMMITTER_EMAIL" \
              "$AUDIT_CANARY_GITHUB_TOKEN" "$AUDIT_CANARY_AGE_KEY" "$AUDIT_CANARY_TAILSCALE_KEY" "$AUDIT_CANARY_CGNAT" "$AUDIT_CANARY_ULA" "127.0.0.1"; do
  grep -qF -- "$canary" <<<"$OUT" && fail "the report leaked a matched value: $canary"
done
echo "the report names rules and locations only; no matched text leaked"

# --- a clean fixture passes -------------------------------------------------------------------------------
make_audit_fixture "$T/clean" clean
audit_deploy --script audit
[[ $RC -eq 0 ]] && grep -q 'clean' <<<"$OUT" || fail "a fixture with no planted canaries must pass (exit 0): got RC=$RC"
echo "a clean fixture passes"

# --- the allowlist: can silence a named rule at a named location, and only that rule -----------------------
make_audit_fixture "$T/allow" dirty
cat > "$T/allow/repo/audit-allowlist.yml" <<'A'
allowlist:
  - path: "tree:notes/cgnat.txt:*"
    rule: "tailnet-cgnat-address"
    reason: "fixture test data, not the operator's real tailnet address"
A
audit_deploy --script audit
[[ $RC -eq 1 ]] || fail "other canaries remain after allowlisting one; must still exit 1 (got $RC)"
grep -q 'FINDING tailnet-cgnat-address tree:notes/cgnat.txt:1' <<<"$OUT" && fail "the allowlisted finding was still reported"
grep -q 'FINDING secret:FIX_AUDIT_SECRET tree:notes/tree-secret.txt:1' <<<"$OUT" || fail "an unrelated finding disappeared too (the allowlist is not scoped to its own entry)"
echo "the allowlist silences exactly the (path, rule) it names; every other finding still fails the audit"

cat > "$T/allow/repo/audit-allowlist.yml" <<'A'
allowlist:
  - path: "tree:notes/cgnat.txt:*"
    rule: "not-the-real-rule-name"
    reason: "an allowlist entry must not silence a rule it does not name"
A
audit_deploy --script audit
grep -q 'FINDING tailnet-cgnat-address tree:notes/cgnat.txt:1' <<<"$OUT" || fail "an allowlist entry for the WRONG rule name silenced a finding it does not name"
echo "an allowlist entry cannot silence a rule it does not name"

# --- the lint-run entry point: generic rules, tree only, no key ------------------------------------------
set +e
GENERIC_OUT="$(python3 "$T/dirty/repo/scripts/public-readiness-audit.py" --generic-only --tree-only --root "$T/dirty/repo" 2>&1)"
GENERIC_RC=$?
set -e
[[ $GENERIC_RC -eq 1 ]] || { echo "$GENERIC_OUT" >&2; fail "generic-only --tree-only must still exit 1 on the dirty fixture's tree (got $GENERIC_RC)"; }
grep -q 'FINDING credential-shape:github-token tree:notes/generic-shapes.txt:1' <<<"$GENERIC_OUT" || fail "generic-only mode missed a generic rule"
grep -q 'FINDING tailnet-cgnat-address tree:notes/cgnat.txt:1' <<<"$GENERIC_OUT" || fail "generic-only mode missed the CGNAT rule"
grep -q 'FINDING tailnet-ula-address tree:notes/ula.txt:1' <<<"$GENERIC_OUT" || fail "generic-only mode missed the ULA rule"
grep -q 'secret:FIX_AUDIT_SECRET' <<<"$GENERIC_OUT" && fail "generic-only mode (no key) must not report secret-derived findings"
grep -q 'history:notes/old.key' <<<"$GENERIC_OUT" && fail "tree-only mode must not scan history"
echo "the lint-run entry point (--generic-only --tree-only, no key) finds the generic rules over the tree only"

echo "public-readiness audit guard OK"

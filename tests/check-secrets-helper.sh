#!/usr/bin/env bash
# Epic 22 ticket #04 guard: the secrets helper (scripts/secrets), treated as a BLACK BOX.
#
# Runs the real helper against a throwaway repository tree with two separate "workstation" HOME directories and
# throwaway age keys — no real key or secret is ever needed. A canary value is used throughout, and every assertion
# that a command "did not leak" greps the FULL combined output for it.
#
# What this CANNOT verify: the real store and keys, or ticket #09's actual attended migration.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
FIX_SRC_ROOT="$ROOT_DIR"
# shellcheck source=tests/support/secrets-fixture.sh
source tests/support/secrets-fixture.sh
fail() { echo "FAIL: $*" >&2; [[ -n "${OUT:-}" ]] && { echo "--- output ---" >&2; echo "$OUT" >&2; }; exit 1; }
for tool in sops age age-keygen python3; do command -v "$tool" >/dev/null || { echo "FAIL: $tool is not installed" >&2; exit 1; }; done
export PYTHONDONTWRITEBYTECODE=1
echo "== secrets helper guard (epic 22 #04) =="

no_leak() {  # no_leak <label>  (reads $OUT)
  ! grep -qF -- "$CANARY_VALUE" <<<"$OUT" || fail "$1: the canary value appeared in the output"
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
make_secrets_fixture "$T"

# Baseline of any hermes-secrets-* scratch dirs already present (e.g. orphaned by an unrelated, forcibly-killed
# process on this machine) so the later leak check only flags directories THIS run's own edit calls left behind.
scratch_bases() { for b in "${XDG_RUNTIME_DIR:-}" /dev/shm /tmp; do [[ -n "$b" && -d "$b" ]] && find "$b" -maxdepth 1 -name 'hermes-secrets-*' 2>/dev/null; done; }
SCRATCH_BASELINE="$(scratch_bases)"

# --- init-key: safe permissions, public key only, never overwrites -----------------------------------------------
PUB1="$(new_key "$FIX_HOME1")"
[[ "$PUB1" =~ ^age1[a-z0009]{58}$ || "$PUB1" =~ ^age1[a-z0-9]{58}$ ]] || fail "init-key did not print a plain age public key (got: $PUB1)"
KEY1="$FIX_HOME1/.config/sops/age/keys.txt"
[[ -f "$KEY1" ]] || fail "init-key did not create the key file"
mode="$(stat -c '%a' "$KEY1")"; [[ "$mode" == "600" ]] || fail "init-key left the key file at mode $mode, not 600"
! grep -q 'AGE-SECRET-KEY' <<<"$PUB1" || fail "init-key printed the private key, not just the public one"
run_secrets "$FIX_HOME1" -- init-key; [[ $RC -ne 0 ]] || fail "init-key must refuse to overwrite an existing key"
PUB2="$(new_key "$FIX_HOME2")"
BGKEY="$FIX_BG_DIR/breakglass.txt"
run_secrets "$FIX_BG_DIR" -- init-key "$BGKEY"
[[ $RC -eq 0 ]] || fail "init-key at an explicit path failed (rc=$RC)"
PUBBG="$OUT"
[[ -f "$BGKEY" ]] && [[ "$(stat -c '%a' "$BGKEY")" == "600" ]] || fail "init-key at an explicit path did not create a 0600 file"
echo "init-key: safe permissions, public key only, refuses to overwrite"

# --- bootstrap: add-recipient before any store exists creates .sops.yaml -----------------------------------------
[[ ! -f "$FIX_REPO/.sops.yaml" ]] || fail "test setup: .sops.yaml should not exist yet"
run_secrets "$FIX_HOME1" -- add-recipient "$PUB1"
[[ $RC -eq 0 ]] && [[ -f "$FIX_REPO/.sops.yaml" ]] || fail "add-recipient did not bootstrap .sops.yaml (rc=$RC)"
grep -q "$PUB1" "$FIX_REPO/.sops.yaml" || fail "the bootstrap .sops.yaml does not list the recipient"
run_secrets "$FIX_HOME1" -- add-recipient "$PUBBG"
[[ $RC -eq 0 ]] && grep -q "$PUBBG" "$FIX_REPO/.sops.yaml" || fail "a second add-recipient (still no store) did not append"
run_secrets "$FIX_HOME1" -- add-recipient "not-an-age-key"
[[ $RC -eq 64 ]] && ! grep -q "not-an-age-key" "$FIX_REPO/.sops.yaml" || fail "an invalid recipient must be refused, not written (rc=$RC)"
# Right shape (age1 + 58 chars from the bech32 alphabet), wrong checksum: this must be rejected by the checksum
# verification itself, not merely by the length/alphabet regex — a same-length, same-alphabet lookalike is exactly
# what the checksum exists to catch (a typo'd or truncated-and-repaired key must never be silently accepted).
BADCHECKSUM="${PUB1%?}$([ "${PUB1: -1}" = "q" ] && echo p || echo q)"
[[ "$BADCHECKSUM" =~ ^age1[a-z0-9]{58}$ ]] || fail "test setup: BADCHECKSUM does not even have the right shape"
run_secrets "$FIX_HOME1" -- add-recipient "$BADCHECKSUM"
[[ $RC -eq 64 ]] && ! grep -qF "$BADCHECKSUM" "$FIX_REPO/.sops.yaml" || fail "a right-shaped but checksum-invalid recipient must be refused, not written (rc=$RC)"
echo "bootstrap: add-recipient creates .sops.yaml when no store exists, refuses an invalid key (shape AND checksum)"

# --- import: verified round trip, missing/undeclared reporting, nothing printed ----------------------------------
printf 'FIX_TOKEN=%s\nFIX_DOMAIN=fixture.example\nTARGET_HOST=host.example\n' "$CANARY_VALUE" > "$T/plain/clean.env"
run_secrets "$FIX_HOME1" -- import "$T/plain/clean.env"
[[ $RC -eq 0 ]] && grep -q 'round-trip verified' <<<"$OUT" || fail "a clean import must succeed (rc=$RC)"
no_leak "import (clean)"
[[ -f "$FIX_REPO/secrets/secrets.enc.env" ]] || fail "import did not create the store"
grep -qE "^FIX_TOKEN=ENC\[" "$FIX_REPO/secrets/secrets.enc.env" || fail "the store does not look encrypted"
run_secrets "$FIX_HOME1" -- check
[[ $RC -eq 0 ]] && grep -q 'OK' <<<"$OUT" || fail "check must pass after a clean import (rc=$RC, out=$OUT)"

printf 'FIX_TOKEN=%s\nTARGET_HOST=h\n' "$CANARY_VALUE" > "$T/plain/missingdomain.env"   # FIX_DOMAIN (required) absent
run_secrets "$FIX_HOME1" -- import "$T/plain/missingdomain.env"
[[ $RC -eq 0 ]] && grep -q 'still missing (required): FIX_DOMAIN' <<<"$OUT" || fail "import must report a still-missing required name (rc=$RC)"
no_leak "import (missing required)"

printf 'FIX_TOKEN=%s\nFIX_DOMAIN=d\nTARGET_HOST=h\nSTRAY_EXTRA=%s\n' "$CANARY_VALUE" "$CANARY_VALUE" > "$T/plain/undeclared.env"
run_secrets "$FIX_HOME1" -- import "$T/plain/undeclared.env"
[[ $RC -eq 0 ]] && grep -q 'undeclared names carried over from the source: STRAY_EXTRA' <<<"$OUT" || fail "import must report an undeclared name carried from the source (rc=$RC)"
no_leak "import (undeclared)"
run_secrets "$FIX_HOME1" -- check
[[ $RC -eq 1 ]] && grep -q 'STRAY_EXTRA' <<<"$OUT" || fail "check must flag the undeclared name the import just carried over (rc=$RC)"

printf 'FIX_TOKEN=%s\nFIX_DOMAIN=fixture.example\nFIX_OPT=\nTARGET_HOST=host.example\n' "$CANARY_VALUE" > "$T/plain/optabsent.env"
run_secrets "$FIX_HOME1" -- import "$T/plain/optabsent.env"
[[ $RC -eq 0 ]] || fail "an import with an optional name explicitly empty must still succeed (rc=$RC)"
no_leak "import (optional empty)"
run_secrets "$FIX_HOME1" -- check; [[ $RC -eq 0 ]] || fail "check must pass with an optional name empty (rc=$RC, out=$OUT)"

run_secrets "$FIX_HOME1" -- import "$T/plain/does-not-exist.env"
[[ $RC -ne 0 ]] || fail "import of a missing source file must fail"
printf '' > "$T/plain/empty.env"
run_secrets "$FIX_HOME1" -- import "$T/plain/empty.env"
[[ $RC -ne 0 ]] || fail "import of an empty source file must fail"
run_secrets "$FIX_HOME2" -- import "$T/plain/clean.env"
[[ $RC -ne 0 ]] && ! grep -qi 'traceback' <<<"$OUT" || fail "import must fail cleanly (not a traceback) for a workstation with no key yet (rc=$RC)"
# A duplicate NAME= line in the source is refused up front: sops' own dotenv parser would silently pick one of the
# two values consistently on both sides of the round-trip check, so that check alone could never notice the loss.
printf 'FIX_TOKEN=%s\nFIX_TOKEN=second-value-should-never-land\nFIX_DOMAIN=d\nTARGET_HOST=h\n' "$CANARY_VALUE" > "$T/plain/dupe.env"
run_secrets "$FIX_HOME1" -- import "$T/plain/dupe.env"
[[ $RC -ne 0 ]] && grep -q 'FIX_TOKEN' <<<"$OUT" || fail "import must refuse a source with a duplicate NAME= assignment (rc=$RC)"
no_leak "import (duplicate name)"
! grep -qF 'second-value-should-never-land' <<<"$OUT" || fail "import must report a duplicate by name only, never the value"
echo "import: verified round trip; missing/undeclared/optional-empty/duplicate reported by name only; nothing printed; clean failures"

run_secrets "$FIX_HOME1" -- import "$T/plain/clean.env"   # restore a clean single-name store for what follows
[[ $RC -eq 0 ]] || fail "test setup: could not restore a clean store"

# --- check: keyless (structure only) ------------------------------------------------------------------------------
run_secrets "$FIX_HOME2" -- check   # FIX_HOME2 has no key for this store at all
[[ $RC -eq 0 ]] && grep -q 'OK' <<<"$OUT" || fail "check must not need a key: it only looks at the store's visible names (rc=$RC, out=$OUT)"
mv "$FIX_REPO/secrets/secrets.enc.env" "$T/store.bak"
run_secrets "$FIX_HOME1" -- check
[[ $RC -eq 78 ]] || fail "check with no store yet must fail cleanly (rc=$RC)"
mv "$T/store.bak" "$FIX_REPO/secrets/secrets.enc.env"
echo "check: needs no key (reads only the store's visible names); fails cleanly with no store"

# --- fill: real hidden-input path (a pseudo-terminal), nothing missing, non-interactive refusal --------------------
run_secrets "$FIX_HOME1" -- fill
[[ $RC -eq 0 ]] && grep -q 'nothing required is missing' <<<"$OUT" || fail "fill with nothing missing must say so (rc=$RC)"
echo "$CANARY_VALUE" | run_secrets "$FIX_HOME1" -- fill
[[ $RC -eq 0 ]] || fail "fill with nothing missing, given piped stdin, must still just report nothing missing (rc=$RC)"

( cd "$FIX_REPO" && printf 'FIX_DOMAIN=fixture.example\nTARGET_HOST=host.example\n' \
    | SOPS_AGE_KEY_FILE="$KEY1" sops encrypt --input-type dotenv --output-type dotenv --filename-override secrets/secrets.enc.env > "$T/s.tmp" \
    && cp "$T/s.tmp" secrets/secrets.enc.env )   # FIX_TOKEN now missing
run_secrets "$FIX_HOME1" -- fill   # non-interactive (no tty): must refuse, not silently skip or hang
[[ $RC -eq 78 ]] && grep -q 'FIX_TOKEN' <<<"$OUT" || fail "fill must refuse non-interactively rather than hang or skip silently (rc=$RC)"

fill_via_pty "$FIX_HOME1" "$CANARY_VALUE"
[[ $RC -eq 0 ]] && grep -q 'store updated' <<<"$OUT" || fail "the real pty-driven fill must succeed (rc=$RC)"
no_leak "fill (pty transcript, echo must be off)"
decrypt_as "$FIX_HOME1" -- "$FIX_REPO/secrets/secrets.enc.env"
[[ $RC -eq 0 ]] && grep -qF "$CANARY_VALUE" <<<"$OUT" || fail "the filled value was not actually stored"

( cd "$FIX_REPO" && printf 'FIX_TOKEN=x\nFIX_DOMAIN=fixture.example\nTARGET_HOST=host.example\n' \
    | SOPS_AGE_KEY_FILE="$KEY1" sops encrypt --input-type dotenv --output-type dotenv --filename-override secrets/secrets.enc.env > "$T/s.tmp" \
    && cp "$T/s.tmp" secrets/secrets.enc.env )
fill_via_pty "$FIX_HOME1"   # nothing missing now — no prompt should appear, no values consumed
[[ $RC -eq 0 ]] && grep -q 'nothing required is missing' <<<"$OUT" || fail "pty fill with nothing missing must not prompt (rc=$RC, out=$OUT)"
echo "fill: a real pseudo-terminal drives the hidden-input path with no echo; refuses non-interactively; no-op when nothing is missing"

# --- edit: sops edit, a no-op and a real change, TMPDIR private -----------------------------------------------------
run_secrets "$FIX_HOME1" EDITOR=true -- edit
[[ $RC -eq 0 ]] || fail "edit with an editor that makes no change must still succeed (rc=$RC)"
cat > "$T/editor.sh" <<E
#!/usr/bin/env bash
printf 'FIX_TOKEN=x\nFIX_DOMAIN=%s\nTARGET_HOST=host.example\n' '$CANARY_VALUE' > "\$1"
E
chmod +x "$T/editor.sh"
run_secrets "$FIX_HOME1" EDITOR="$T/editor.sh" -- edit
[[ $RC -eq 0 ]] || fail "edit with a real change must succeed (rc=$RC)"
no_leak "edit"
decrypt_as "$FIX_HOME1" -- "$FIX_REPO/secrets/secrets.enc.env"
grep -qF "$CANARY_VALUE" <<<"$OUT" || fail "edit's change was not actually stored"
cat > "$T/editor-check-tmpdir.sh" <<E
#!/usr/bin/env bash
[[ "\$1" == "\$TMPDIR"/* ]] && echo -n "PRIVATE-TMPDIR-OK" > "$T/tmpdir-check" || echo -n "SHARED" > "$T/tmpdir-check"
cat "\$1" > /dev/null
E
chmod +x "$T/editor-check-tmpdir.sh"
run_secrets "$FIX_HOME1" EDITOR="$T/editor-check-tmpdir.sh" -- edit
[[ "$(cat "$T/tmpdir-check" 2>/dev/null)" == "PRIVATE-TMPDIR-OK" ]] || fail "edit's temp file was not under a TMPDIR this wrapper pinned"
run_secrets "$FIX_HOME1" -- import "$T/plain/clean.env" >/dev/null   # restore
NEW_SCRATCH="$(comm -13 <(sort <<<"$SCRATCH_BASELINE") <(scratch_bases | sort))"
[[ -z "$NEW_SCRATCH" ]] || fail "edit left its scratch directory behind: $NEW_SCRATCH"
echo "edit: sops edit round-trips a no-op and a real change without leaking; its temp file lives under a pinned TMPDIR, cleaned up after"

# --- add-recipient / remove-recipient on an EXISTING store: re-keys, and access genuinely changes ------------------
# `add-recipient` must be run by someone ALREADY able to decrypt (sops updatekeys needs an existing recipient to
# re-wrap the data key) — the onboarding flow is an EXISTING workstation adding the NEW one's public key, never the
# new workstation adding itself (it has no access to re-wrap with yet, and correctly can't: tested here as a bug in
# an earlier draft of this very test, not in the helper).
run_secrets "$FIX_HOME1" -- add-recipient "$PUB2"
[[ $RC -eq 0 ]] && grep -q 're-keyed the store' <<<"$OUT" || fail "add-recipient on an existing store must re-key it (rc=$RC)"
decrypt_as "$FIX_HOME2" -- "$FIX_REPO/secrets/secrets.enc.env"
[[ $RC -eq 0 ]] || fail "the newly added recipient must actually be able to decrypt (rc=$RC)"
run_secrets "$FIX_HOME1" -- add-recipient "$PUB2"
[[ $RC -eq 0 ]] && grep -q 'already a recipient' <<<"$OUT" || fail "adding the same recipient twice must be a clean no-op (rc=$RC)"

run_secrets "$FIX_HOME1" -- remove-recipient "$PUB2"
[[ $RC -eq 0 ]] && grep -q 'does NOT protect' <<<"$OUT" || fail "remove-recipient must succeed and carry the history warning (rc=$RC)"
decrypt_as "$FIX_HOME2" -- "$FIX_REPO/secrets/secrets.enc.env"
[[ $RC -ne 0 ]] || fail "a removed recipient must no longer be able to decrypt (this is the whole point of the command)"
decrypt_as "$FIX_HOME1" -- "$FIX_REPO/secrets/secrets.enc.env"
[[ $RC -eq 0 ]] || fail "the remaining recipient must still be able to decrypt after a removal"

run_secrets "$FIX_HOME1" -- add-recipient "$PUBBG"   # back up to 2 recipients (workstation 1 + break-glass)
[[ $RC -eq 0 ]] || fail "test setup: re-adding the break-glass recipient failed"
run_secrets "$FIX_HOME1" -- remove-recipient "$PUB1"   # remove the LAST recipient other than break-glass: 1 left, must succeed
[[ $RC -eq 0 ]] || fail "removing down to exactly one recipient must still succeed (rc=$RC)"
run_secrets "$FIX_BG_DIR" HERMES_SECRETS_KEY_FILE="$BGKEY" -- remove-recipient "$PUBBG"   # now try to remove the ONLY remaining recipient
[[ $RC -eq 64 ]] && grep -q 'refusing to remove the only recipient' <<<"$OUT" || fail "removing the LAST recipient must be refused (rc=$RC)"
decrypt_as "$FIX_BG_DIR" SOPS_AGE_KEY_FILE="$BGKEY" -- "$FIX_REPO/secrets/secrets.enc.env"
[[ $RC -eq 0 ]] || fail "the sole remaining recipient must still decrypt after the refused removal"
run_secrets "$FIX_BG_DIR" HERMES_SECRETS_KEY_FILE="$BGKEY" -- add-recipient "$PUB1"   # restore a 2-recipient state for later tests
[[ $RC -eq 0 ]] || fail "test setup: restoring the workstation recipient failed"
no_leak "add/remove-recipient sequence"
echo "add-recipient/remove-recipient: re-key an existing store; a removed key genuinely loses access; the last recipient can't be removed"

# --- add-recipient/remove-recipient: if `sops updatekeys` fails partway through, .sops.yaml is rolled back rather
# than left claiming a recipient set the real ciphertext doesn't have (a permission hiccup, a full disk, or a
# Ctrl-C landing in that exact window are all realistic; this must never leave the two silently out of sync) --------
cp "$FIX_REPO/.sops.yaml" "$T/sops.yaml.before"
chmod 555 "$FIX_REPO/secrets"; chmod 444 "$FIX_REPO/secrets/secrets.enc.env"   # block both a temp+rename and a direct truncate-write
run_secrets "$FIX_HOME1" -- remove-recipient "$PUBBG"
RC_REMOVE=$RC; OUT_REMOVE="$OUT"
chmod 755 "$FIX_REPO/secrets"; chmod 644 "$FIX_REPO/secrets/secrets.enc.env"
[[ $RC_REMOVE -ne 0 ]] || fail "remove-recipient must fail when sops updatekeys can't write the store (test setup: RC=$RC_REMOVE)"
diff -q "$T/sops.yaml.before" "$FIX_REPO/.sops.yaml" >/dev/null \
  || fail "a failed updatekeys must roll .sops.yaml back — it must not record a recipient change the store never got"
decrypt_as "$FIX_BG_DIR" SOPS_AGE_KEY_FILE="$BGKEY" -- "$FIX_REPO/secrets/secrets.enc.env"
[[ $RC -eq 0 ]] || fail "after a rolled-back removal, the 'removed' recipient must still actually decrypt (config and store must agree)"
echo "add-recipient/remove-recipient: a failed updatekeys rolls .sops.yaml back instead of leaving it out of sync with the store"

# --- .sops.yaml with more than one matching creation_rules entry: the FIRST match is used, exactly like sops itself
# resolves recipients — never a later, coincidentally-also-matching rule (a hand-edited multi-rule file is the only
# way this can happen; sops's own semantics are "first match wins", so this tool must agree with it) ----------------
cp "$FIX_REPO/.sops.yaml" "$T/sops.yaml.single"
cat > "$FIX_REPO/.sops.yaml" <<YAML
creation_rules:
  - path_regex: '^secrets/secrets\.enc\.env$'
    key_groups:
      - age:
          - $PUB1
          - $PUBBG
  - path_regex: '.*'
    key_groups:
      - age:
          - $PUB2
YAML
run_secrets "$FIX_HOME1" -- add-recipient "$PUB2"
[[ $RC -eq 0 ]] && grep -q 're-keyed the store' <<<"$OUT" || fail "add-recipient with more than one matching rule must act on the FIRST match, not no-op against a later one (rc=$RC, out=$OUT)"
FIRST_RULE="$(awk '/path_regex/{n++} n==1' "$FIX_REPO/.sops.yaml")"
SECOND_RULE="$(awk '/path_regex/{n++} n==2' "$FIX_REPO/.sops.yaml")"
grep -qF "$PUB2" <<<"$FIRST_RULE" || fail "add-recipient did not append to the FIRST matching creation_rules entry"
[[ "$(grep -cF "$PUB2" <<<"$SECOND_RULE")" -eq 1 ]] || fail "test setup: the second rule should be untouched, still listing only its original recipient"
decrypt_as "$FIX_HOME1" -- "$FIX_REPO/secrets/secrets.enc.env"; RC1=$RC
decrypt_as "$FIX_BG_DIR" SOPS_AGE_KEY_FILE="$BGKEY" -- "$FIX_REPO/secrets/secrets.enc.env"; RC2=$RC
[[ $RC1 -eq 0 && $RC2 -eq 0 ]] || fail "using the first matching rule must keep the existing recipients valid (rc1=$RC1 rc2=$RC2)"
run_secrets "$FIX_HOME1" -- remove-recipient "$PUB2"   # cleanup: drop the throwaway extra recipient from the real store
[[ $RC -eq 0 ]] || fail "test cleanup: removing the multi-rule-test recipient failed (rc=$RC)"
cp "$T/sops.yaml.single" "$FIX_REPO/.sops.yaml"   # cleanup: drop the throwaway second rule, back to the original single rule
echo "add-recipient/remove-recipient: with more than one matching .sops.yaml rule, the first match is used, exactly like sops"

# --- add-recipient must never bootstrap a fresh .sops.yaml for a store that ALREADY exists: guessing a single-
# recipient config from just the one key on the command line could either let an identity that can't actually
# decrypt claim ownership (updatekeys would silently fail behind it) or, if the caller genuinely can decrypt, drop
# every OTHER real recipient without any confirmation. Neither is safe to guess at, so both must be refused. --------
cp "$FIX_REPO/.sops.yaml" "$T/sops.yaml.bootstrap_backup"
rm "$FIX_REPO/.sops.yaml"   # simulate .sops.yaml lost (bad merge, sparse checkout) while the store remains
run_secrets "$FIX_HOME1" -- add-recipient "$PUB1"   # even a REAL, currently-valid recipient must be refused here
[[ $RC -ne 0 ]] && [[ ! -f "$FIX_REPO/.sops.yaml" ]] || fail "add-recipient must refuse to bootstrap .sops.yaml for a store that already exists, even for a valid recipient (rc=$RC)"
decrypt_as "$FIX_HOME1" -- "$FIX_REPO/secrets/secrets.enc.env"; RC1=$RC
decrypt_as "$FIX_BG_DIR" SOPS_AGE_KEY_FILE="$BGKEY" -- "$FIX_REPO/secrets/secrets.enc.env"; RC2=$RC
[[ $RC1 -eq 0 && $RC2 -eq 0 ]] || fail "a refused bootstrap must leave the real store's recipients completely untouched (rc1=$RC1 rc2=$RC2)"
cp "$T/sops.yaml.bootstrap_backup" "$FIX_REPO/.sops.yaml"
echo "add-recipient: never bootstraps a fresh .sops.yaml for a store that already exists (refuses, does not guess)"

# --- a symlinked store is refused outright at the point of use, for every command that reads or writes it, never
# silently followed to whatever it points at ------------------------------------------------------------------------
mv "$FIX_REPO/secrets/secrets.enc.env" "$T/real-store-for-symlink-test.env"
ln -s "$T/real-store-for-symlink-test.env" "$FIX_REPO/secrets/secrets.enc.env"
for cmd in check rotate fill; do
  run_secrets "$FIX_HOME1" -- "$cmd"
  [[ $RC -ne 0 ]] && grep -qi 'symlink' <<<"$OUT" || fail "'secrets $cmd' must refuse a symlinked store, not follow it (rc=$RC, out=$OUT)"
done
run_secrets "$FIX_HOME1" EDITOR=true -- edit
[[ $RC -ne 0 ]] && grep -qi 'symlink' <<<"$OUT" || fail "'secrets edit' must refuse a symlinked store, not follow it (rc=$RC, out=$OUT)"
rm "$FIX_REPO/secrets/secrets.enc.env"
mv "$T/real-store-for-symlink-test.env" "$FIX_REPO/secrets/secrets.enc.env"
echo "a symlinked store is refused outright by check/edit/rotate/fill, never followed"

# --- check reports a missing required name (not just import's echo of the same underlying function) ----------------
( cd "$FIX_REPO" && printf 'FIX_DOMAIN=fixture.example\nTARGET_HOST=host.example\n' \
    | SOPS_AGE_KEY_FILE="$KEY1" sops encrypt --input-type dotenv --output-type dotenv --filename-override secrets/secrets.enc.env > "$T/s.tmp" \
    && cp "$T/s.tmp" secrets/secrets.enc.env )   # FIX_TOKEN (required) absent
run_secrets "$FIX_HOME1" -- check
[[ $RC -eq 1 ]] && grep -q 'missing (required): FIX_TOKEN' <<<"$OUT" || fail "check must report a missing required name itself, not just via import (rc=$RC, out=$OUT)"
run_secrets "$FIX_HOME1" -- import "$T/plain/clean.env" >/dev/null   # restore
echo "check: reports a missing required name directly"

# --- fill treats a required name that is PRESENT BUT EMPTY as still missing (not just an absent optional one) -------
( cd "$FIX_REPO" && printf 'FIX_TOKEN=\nFIX_DOMAIN=fixture.example\nTARGET_HOST=host.example\n' \
    | SOPS_AGE_KEY_FILE="$KEY1" sops encrypt --input-type dotenv --output-type dotenv --filename-override secrets/secrets.enc.env > "$T/s.tmp" \
    && cp "$T/s.tmp" secrets/secrets.enc.env )   # FIX_TOKEN (required) present but empty
run_secrets "$FIX_HOME1" -- fill   # non-interactive: must refuse citing FIX_TOKEN, not treat empty-but-present as satisfied
[[ $RC -ne 0 ]] && grep -q 'FIX_TOKEN' <<<"$OUT" || fail "fill must treat a required name that is present but empty as still missing (rc=$RC, out=$OUT)"
run_secrets "$FIX_HOME1" -- import "$T/plain/clean.env" >/dev/null   # restore
echo "fill: a required name that is present but empty still counts as missing"

# --- rotate: values survive, both recipients still work, data key actually changes ---------------------------------
grep -o '^sops_age__list_0__map_enc=.*$' "$FIX_REPO/secrets/secrets.enc.env" > "$T/enc0.before"
run_secrets "$FIX_HOME1" -- rotate
[[ $RC -eq 0 ]] && grep -q 'data encryption key has been replaced' <<<"$OUT" || fail "rotate must succeed (rc=$RC)"
grep -o '^sops_age__list_0__map_enc=.*$' "$FIX_REPO/secrets/secrets.enc.env" > "$T/enc0.after"
! diff -q "$T/enc0.before" "$T/enc0.after" >/dev/null || fail "rotate did not actually change the wrapped data key"
decrypt_as "$FIX_HOME1" -- "$FIX_REPO/secrets/secrets.enc.env"; RC1=$RC; OUT1="$OUT"
decrypt_as "$FIX_BG_DIR" SOPS_AGE_KEY_FILE="$BGKEY" -- "$FIX_REPO/secrets/secrets.enc.env"; RC2=$RC
[[ $RC1 -eq 0 && $RC2 -eq 0 ]] || fail "both recipients must still decrypt after rotate (rc1=$RC1 rc2=$RC2)"
grep -q '"FIX_TOKEN"' <<<"$OUT1" || fail "rotate must not change the values"
run_secrets "$FIX_HOME1" -- rotate   # no store case
mv "$FIX_REPO/secrets/secrets.enc.env" "$T/store.bak2"
run_secrets "$FIX_HOME1" -- rotate
[[ $RC -eq 78 ]] || fail "rotate with no store must fail cleanly (rc=$RC)"
mv "$T/store.bak2" "$FIX_REPO/secrets/secrets.enc.env"
echo "rotate: the data key genuinely changes; both recipients still decrypt; values unchanged; fails cleanly with no store"

# --- every write is atomic: no partial/temp file ever left next to the store -------------------------------------
# This can only catch a temp file left BEHIND (e.g. a crash mid-write); it cannot black-box-prove the write was
# atomic in the first place (a direct, non-atomic write that still succeeds looks identical from the outside without
# fault injection at the syscall level, which is out of scope here). write_atomic()'s use of mkstemp+os.replace is
# reviewed by code inspection instead.
find "$FIX_REPO/secrets" -maxdepth 1 -name '.secrets.enc.env.*' 2>/dev/null | grep -q . \
  && fail "a temp file was left next to the store (writes must be atomic: temp file + rename)"
echo "every store write leaves no temp file behind (atomic replace)"

# --- sops failures never leak sops' own diagnostic text (raw wording, "Group N", key fingerprints, ENC[...] blobs) --
# The reported message DOES legitimately include the store's own file path (an operator-known path, not a secret) —
# that is not a leak. What must never appear is sops' own raw diagnostic vocabulary.
no_raw_sops_text() {  # no_raw_sops_text <label>  (reads $OUT)
  ! grep -qE 'Group [0-9]|age1[a-z0-9]{58}|ENC\[|unmarshal|MAC mismatch|\.go:[0-9]' <<<"$OUT" \
    || fail "$1: a sops failure leaked its own raw diagnostic text: $OUT"
}
cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.forcorrupt"
sed -i -E 's/^(sops_mac=ENC\[AES256_GCM,data:)[A-Za-z0-9+\/=]+/\1QQQQQQQQ/' "$FIX_REPO/secrets/secrets.enc.env"
run_secrets "$FIX_HOME1" -- rotate
[[ $RC -ne 0 ]] || fail "rotate on a corrupted store must fail"
grep -qF "the store's integrity check failed" <<<"$OUT" || fail "rotate on a corrupted store must report the fixed-vocabulary integrity-check reason: $OUT"
no_raw_sops_text "rotate"
run_secrets "$FIX_HOME1" -- fill
[[ $RC -ne 0 ]] || fail "fill on a corrupted store must fail"
grep -qF "the store's integrity check failed" <<<"$OUT" || fail "fill on a corrupted store must report the fixed-vocabulary integrity-check reason: $OUT"
no_raw_sops_text "fill"
run_secrets "$FIX_HOME1" EDITOR=true -- edit
[[ $RC -ne 0 ]] || fail "edit on a corrupted store must fail"
grep -qF "the store's integrity check failed" <<<"$OUT" || fail "edit on a corrupted store must report the fixed-vocabulary integrity-check reason: $OUT"
no_raw_sops_text "edit"
cp "$T/store.forcorrupt" "$FIX_REPO/secrets/secrets.enc.env"
# The exact scenario a real key file, not a store, ends up at HERMES_SECRETS_STORE (a plausible misconfiguration):
# sops fails to parse it, and that failure must go through the same mapping — never echo the file's real content.
run_secrets "$FIX_HOME1" HERMES_SECRETS_STORE="$KEY1" EDITOR=true -- edit
[[ $RC -ne 0 ]] || fail "edit against a non-store file (here: an age key file) must fail"
! grep -qF 'AGE-SECRET-KEY' <<<"$OUT" || fail "edit against a misconfigured HERMES_SECRETS_STORE leaked private key material: $OUT"
no_raw_sops_text "edit (misconfigured store path)"
# sops only WARNS (rc 0, or 200 for edit's own "no changes made") about a forged/unencrypted comment line; edit must
# refuse it exactly like decrypt_store() already does for every other command, never silently succeed.
cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.forged.bak"
printf '#ENC[AES256_GCM,data:aGVsbG8=,iv:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:comment]\n' >> "$FIX_REPO/secrets/secrets.enc.env"
run_secrets "$FIX_HOME1" EDITOR=true -- edit
[[ $RC -ne 0 ]] && grep -q 'comment line that is not properly encrypted' <<<"$OUT" || fail "edit must refuse a store with a forged/unencrypted comment line (rc=$RC, out=$OUT)"
! grep -q 'aGVsbG8' <<<"$OUT" || fail "edit echoed the forged comment's content"
cp "$T/store.forged.bak" "$FIX_REPO/secrets/secrets.enc.env"
echo "a sops failure is reported in a fixed vocabulary, never sops' own diagnostic text (including from edit); edit also refuses a forged unencrypted comment"

# --- import: a genuine round-trip mismatch is caught, by name only (forced via a monkeypatch — sops's own dotenv
# parser is deterministic, so no real input reproduces a mismatch; this proves the CODE that handles one, not that
# one can occur in practice) ------------------------------------------------------------------------------------
( cd "$FIX_REPO" && env -i PATH="$PATH" HOME="$FIX_HOME1" python3 - "$T/plain/clean.env" <<'PY'
import os, sys
root = os.getcwd()
sys.path.insert(0, os.path.join(root, "scripts"))
import importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("secrets_mod", os.path.join(root, "scripts", "secrets"))
spec = importlib.util.spec_from_loader("secrets_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.hs.decrypt_store = lambda path, environ=None: {"FIX_TOKEN": "WRONG-VALUE", "TARGET_HOST": "host.example"}  # simulate a lossy round trip
class A: plaintext_env_file = sys.argv[1]
rc = mod.cmd_import(A(), os.environ)
sys.exit(0 if rc != 0 else 1)   # this call must itself report failure
PY
) || fail "a forced round-trip mismatch was not detected"
run_secrets "$FIX_HOME1" -- import "$T/plain/clean.env"; [[ $RC -eq 0 ]] || fail "test setup: could not restore a clean store after the monkeypatch test"
echo "import: a round-trip mismatch (values or names changed, or lost) is detected and reported by name only"

# --- init-key: a second attempt never overwrites the existing key, whichever layer refuses it -----------------------
cp "$KEY1" "$T/key1.before"
run_secrets "$FIX_HOME1" -- init-key
[[ $RC -ne 0 ]] && cmp -s "$KEY1" "$T/key1.before" || fail "a repeated init-key must never overwrite the existing key"
echo "init-key never overwrites an existing key"

# --- names-only template stays in sync; setup-env.sh is a static pointer, never prompts -----------------------------
python3 scripts/generate-env.py --check >/dev/null || fail "the real repository's .env.template must be in sync with the manifest"
[[ -x setup-env.sh ]] || fail "setup-env.sh must still be executable (a clear pointer, not a dangling reference)"
set +e; OUT="$(echo | ./setup-env.sh 2>&1)"; RC=$?; set -e
[[ $RC -ne 0 ]] && grep -qi 'secrets' <<<"$OUT" && ! grep -q 'Enter ' <<<"$OUT" || fail "setup-env.sh must point at the helper and never prompt (rc=$RC)"
! grep -q "generate-env.py --check" <<<"$(grep -A2 'setup-env' scripts/generate-env.py | head -1)" 2>/dev/null || true
grep -q 'setup-env.sh' scripts/generate-env.py && ! grep -q '^SETUP = ' scripts/generate-env.py || fail "generate-env.py must no longer treat setup-env.sh as a generated file"
echo "the .env.template stays in sync; setup-env.sh is a static, non-prompting pointer to the helper"

echo "secrets helper guard OK"

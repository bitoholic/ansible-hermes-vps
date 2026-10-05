# Sourced by tests/check-export-public.sh. Builds a throwaway git repository with real, multi-commit
# history (unlike tests/support/deploy-fixture.sh's plain tree) — this seam needs real commits, messages
# and an encrypted-store-then-removed history, not just a working tree. No real key or secret is ever
# needed.
#
#   make_export_fixture DIR   -> creates DIR/{repo,home,run,tmp,keys,plain}; sets
#                                 FIX_REPO FIX_HOME FIX_RUN FIX_TMP FIX_KEY
#   export_deploy [args...]   -> runs the fixture's deploy wrapper from an unrelated cwd, with a
#                                 confined environment (EXPORT_AUTHOR_NAME/EMAIL passed through
#                                 explicitly, since env -i clears everything else); output in $OUT,
#                                 status in $RC
#
# Canary values (fixture only; not secrets). Three pairs exercise the shared-value substitution-
# conflict fix in different ways:
#   FIX_SECRET                               a plain, unshared value: the scrub baseline case.
#   FIX_SHARED_SECRET_A (allowlisted "*") /
#   FIX_SHARED_SECRET_B (not allowlisted)    share EXPORT_CANARY_SHARED: proves that ONE sharer being
#                                             "*"-allowlisted protects the value EVERYWHERE, not just
#                                             under the allowlisted name.
#   FIX_DUP_SECRET_A / FIX_DUP_SECRET_B       share EXPORT_CANARY_DUP, NEITHER allowlisted: proves two
#                                             unrelated secrets with an identical, un-rotated value
#                                             collapse into ONE consistent substitution instead of
#                                             corrupting each other (the bug this fix actually closed).
# Shape-matching canaries are assembled from pieces so this tracked file's own text does not trip the
# generic rules tests/lint.sh runs over this repository's real tree.
EXPORT_CANARY_SECRET='export-canary-tok-9f8e7d6c'
EXPORT_CANARY_SHARED='export-canary-shared-3c2b1'
EXPORT_CANARY_DUP='export-canary-dup-7a6f5'
EXPORT_CANARY_COMMIT_MSG='export-msgcanary-4b2a1'
EXPORT_CANARY_CGNAT='100.'"70.1.2"
EXPORT_CANARY_CGNAT_EXEMPT='100.'"70.1.3"
EXPORT_CANARY_GITHUB_TOKEN='ghp'"_EXPORTCANARYTOKEN0123456789ABCDEFGHI"   # exactly 36 chars after ghp_

make_export_fixture() {   # make_export_fixture DIR
  local dir="$1" repo="$1/repo"
  FIX_REPO="$repo"; FIX_HOME="$dir/home"; FIX_RUN="$dir/run"; FIX_TMP="$dir/tmp"; FIX_KEY="$dir/keys/key.txt"
  mkdir -p "$repo/scripts" "$repo/group_vars/all" "$repo/secrets" "$repo/notes" \
           "$FIX_HOME" "$FIX_RUN" "$FIX_TMP" "$dir/keys" "$dir/plain"
  chmod 700 "$FIX_RUN"
  local src="${FIX_SRC_ROOT:?}"
  for f in deploy hermes_secrets.py hermes_redact.py hermes_bootstrap.py generate-env.py \
           audit_rules.py public-readiness-audit.py export-public.py history_scrub.py; do
    cp "$src/scripts/$f" "$repo/scripts/$f"
  done
  chmod +x "$repo/scripts/deploy" "$repo/scripts/public-readiness-audit.py" "$repo/scripts/export-public.py"

  cat > "$repo/group_vars/all/secrets.yml" <<'M'
secrets_manifest:
  fix_secret:
    env: FIX_SECRET
    required: true
  fix_shared_secret_a:
    env: FIX_SHARED_SECRET_A
    required: false
  fix_shared_secret_b:
    env: FIX_SHARED_SECRET_B
    required: false
  fix_dup_secret_a:
    env: FIX_DUP_SECRET_A
    required: false
  fix_dup_secret_b:
    env: FIX_DUP_SECRET_B
    required: false
M
  cat > "$repo/scripts/generate-env.py" <<'G'
import collections
ExtraVar = collections.namedtuple("ExtraVar", "env section secret required")
EXTRA = [ExtraVar(env="TARGET_HOST", section="Operator / host", secret=False, required=True)]
G
  cat > "$repo/scripts/registered-scripts.conf" <<'C'
audit            scripts/public-readiness-audit.py
export-public    scripts/export-public.py
C
  echo ".env" > "$repo/.gitignore"
  cat > "$repo/README.md" <<'R'
# Fixture repository

Used only by tests/check-export-public.sh. Nothing in this repository is real.
R

  git -C "$repo" init -q -b main
  GIT_AUTHOR_NAME="Original Author" GIT_AUTHOR_EMAIL="original-author@example.invalid" \
  GIT_COMMITTER_NAME="Original Author" GIT_COMMITTER_EMAIL="original-author@example.invalid" \
    git -C "$repo" add -A
  GIT_AUTHOR_NAME="Original Author" GIT_AUTHOR_EMAIL="original-author@example.invalid" \
  GIT_COMMITTER_NAME="Original Author" GIT_COMMITTER_EMAIL="original-author@example.invalid" \
    git -C "$repo" commit -q -m "init fixture"

  # A tracked file with the shape of the audit's allowlist, so the exported fixture's own full-history
  # audit (export-public.py's own clean-check) has something to consult. "*:notes/fixture-cgnat.txt*"
  # is the exempt entry under test; FIX_SECRET and the shared secrets are never-scrub-allowlisted so the
  # export's commit-identity rewrite (which embeds nothing of theirs) never trips over them, and so the
  # shared-value fix is exercised honestly (both names skip, not just one).
  cat > "$repo/audit-allowlist.yml" <<'A'
allowlist:
  - path: "*"
    rule: "secret:FIX_SHARED_SECRET_A"
    reason: "Fixture: deliberately public, shares a value with another secret (tests the dedup fix)."
  - path: "*:notes/fixture-cgnat.txt*"
    rule: "tailnet-cgnat-address"
    reason: "Fixture: a known-safe synthetic address, exercising the per-file exemption derivation."
A
  printf 'a secret lives in this tracked file: %s\n' "$EXPORT_CANARY_SECRET" > "$repo/notes/tree-secret.txt"
  printf 'a value shared with a never-scrub secret: %s\n' "$EXPORT_CANARY_SHARED" > "$repo/notes/shared-secret.txt"
  printf 'a value shared between two scrubbed secrets: %s\n' "$EXPORT_CANARY_DUP" > "$repo/notes/dup-secret.txt"
  printf 'the functional range constant, never touched: 100.64.0.0/10\n' > "$repo/notes/functional.txt"
  printf 'a real tailnet host address, must be scrubbed: %s\n' "$EXPORT_CANARY_CGNAT" > "$repo/notes/real-cgnat.txt"
  printf 'a known-safe fixture address, must survive: %s\n' "$EXPORT_CANARY_CGNAT_EXEMPT" > "$repo/notes/fixture-cgnat.txt"
  printf '%s\n' "$EXPORT_CANARY_GITHUB_TOKEN" > "$repo/notes/generic-shape.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_NAME="Original Author" GIT_AUTHOR_EMAIL="original-author@example.invalid" \
  GIT_COMMITTER_NAME="Original Author" GIT_COMMITTER_EMAIL="original-author@example.invalid" \
    git -C "$repo" commit -q -m "add canary content"

  age-keygen -o "$FIX_KEY" >/dev/null 2>&1
  chmod 600 "$FIX_KEY"
  local pub; pub="$(age-keygen -y "$FIX_KEY")"
  cat > "$repo/.sops.yaml" <<S
creation_rules:
  - path_regex: ^secrets/secrets\.enc\.env\$
    key_groups:
      - age:
          - $pub
S
  local store="$dir/plain/store.env"
  printf 'TARGET_HOST=localhost\nFIX_SECRET=%s\nFIX_SHARED_SECRET_A=%s\nFIX_SHARED_SECRET_B=%s\nFIX_DUP_SECRET_A=%s\nFIX_DUP_SECRET_B=%s\n' \
    "$EXPORT_CANARY_SECRET" "$EXPORT_CANARY_SHARED" "$EXPORT_CANARY_SHARED" "$EXPORT_CANARY_DUP" "$EXPORT_CANARY_DUP" > "$store"
  ( cd "$repo" && sops encrypt --filename-override secrets/secrets.enc.env --input-type dotenv --output-type dotenv "$store" > "$repo/secrets/secrets.enc.env" )
  printf '\x00GITCRYPTKEY\x00\x00\x00\x02' > "$repo/old-domain.example-git-crypt.key"
  git -C "$repo" add -A
  GIT_AUTHOR_NAME="Original Author" GIT_AUTHOR_EMAIL="original-author@example.invalid" \
  GIT_COMMITTER_NAME="Original Author" GIT_COMMITTER_EMAIL="original-author@example.invalid" \
    git -C "$repo" commit -q -m "add the encrypted store and the dead git-crypt key"

  # A real (non-empty) change, so this commit survives pruning — an --allow-empty commit would carry
  # the message canary too, but filter-repo prunes ANY empty commit by default, intentional or not,
  # which would make the message-scrubbing check below pass trivially (no commit, nothing to find)
  # rather than actually proving the scrub ran.
  echo "a later, unrelated change" >> "$repo/notes/tree-secret.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_NAME="Original Author" GIT_AUTHOR_EMAIL="original-author@example.invalid" \
  GIT_COMMITTER_NAME="Original Author" GIT_COMMITTER_EMAIL="original-author@example.invalid" \
    git -C "$repo" commit -q -m "commit message canary: $EXPORT_CANARY_COMMIT_MSG"

  # A lightweight tag on HEAD, the same shape as this real repository's own only tag (v0.0.0-alpha1):
  # no tag object, no tagger identity, no message of its own — just a ref pointing straight at the
  # commit. Proves the clone step's "--single-branch" (no "--no-tags") carries real tags into the
  # export at all; a lightweight tag has nothing for the identity/message scrub to rewrite, so this
  # only exercises "does the ref survive and follow the commit it names", not the scrub itself.
  git -C "$repo" tag v0.0.0-fixture
}

export_deploy() {   # export_deploy [args...] -> $OUT, $RC
  # EXPORT_AUTHOR_NAME/EMAIL are read from the CALLER's environment (not args, see export-public.py's
  # own docstring) and only forwarded through env -i's clean slate when actually set, so a test can omit
  # either to prove the identity is truly required.
  local extra_env=()
  [[ -n "${EXPORT_AUTHOR_NAME:-}" ]] && extra_env+=("EXPORT_AUTHOR_NAME=$EXPORT_AUTHOR_NAME")
  [[ -n "${EXPORT_AUTHOR_EMAIL:-}" ]] && extra_env+=("EXPORT_AUTHOR_EMAIL=$EXPORT_AUTHOR_EMAIL")
  # PYTHONPATH is only forwarded if already set in the CALLER's own environment (e.g. an unusual
  # git-filter-repo install that needs it) — a no-op everywhere git-filter-repo is on PATH normally.
  [[ -n "${PYTHONPATH:-}" ]] && extra_env+=("PYTHONPATH=$PYTHONPATH")
  [[ -n "${AUDIT_EXTRA_TERMS:-}" ]] && extra_env+=("AUDIT_EXTRA_TERMS=$AUDIT_EXTRA_TERMS")
  set +e
  OUT="$(cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" \
        HERMES_SECRETS_KEY_FILE="$FIX_KEY" "${extra_env[@]}" \
        "$FIX_REPO/scripts/deploy" "$@" 2>&1)"
  RC=$?
  set -e
}

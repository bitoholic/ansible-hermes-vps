# Sourced by tests/check-public-readiness-audit.sh. Builds a throwaway GIT repository (unlike
# tests/support/deploy-fixture.sh's plain tree: this seam needs real history, branches and commit
# metadata to scan) that contains a copy of the deploy wrapper and the audit scanner, a fixture
# manifest, a throwaway age key and encrypted store, and — in "dirty" mode — canaries planted in the
# tree, in history (including on a side branch never merged to main, proving "every ref"), in commit
# messages, in commit author/committer metadata, and in JSON-escaped/URL-encoded form. No real key or
# secret is ever needed.
#
#   make_audit_fixture DIR dirty|clean   -> creates DIR/{repo,home,run,tmp,keys,plain}; sets
#                                            FIX_REPO FIX_HOME FIX_RUN FIX_TMP FIX_KEY
#   audit_deploy [args]                  -> runs the fixture's deploy wrapper from an unrelated cwd,
#                                            with a confined environment; output in $OUT, status in $RC
#
# Canary values (fixture only; not secrets):
AUDIT_CANARY_SECRET=$'tok-\xc5\xbc\xc3\xb3\xc5\x82\xc4\x87/9f8e7d6c-canary'   # contains non-ASCII and a slash (UTF-8 bytes)
AUDIT_CANARY_EXTRA='extra-term-zz'
AUDIT_CANARY_HISTORY='history-only-zz'
AUDIT_CANARY_COMMIT_MSG='msgcanary-7f3a1'
AUDIT_CANARY_AUTHOR_NAME='Canary Author'
AUDIT_CANARY_AUTHOR_EMAIL='canary-author@example-canary.test'
AUDIT_CANARY_COMMITTER_NAME='Canary Committer'
AUDIT_CANARY_COMMITTER_EMAIL='canary-committer@example-canary.test'
AUDIT_CANARY_GITHUB_TOKEN='<credential-shape-github-token-redacted>'   # exactly 36 chars after ghp_
# Assembled from pieces (like scripts/check_secrets_store.py's own PRIVATE_KEY_RES) so this file's own
# text does not itself trip the repo-wide "contains private key material" guard.
AUDIT_CANARY_AGE_KEY='AGE-SECRET-'"KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
AUDIT_CANARY_PRIVATE_KEY_HEADER='-----BEGIN PRIVATE '"KEY-----"
AUDIT_CANARY_TAILSCALE_KEY='<credential-shape-tailscale-authkey-redacted>'
AUDIT_CANARY_CGNAT='<tailnet-ip>'

make_audit_fixture() {   # make_audit_fixture DIR dirty|clean
  local dir="$1" mode="$2" repo="$1/repo"
  FIX_REPO="$repo"; FIX_HOME="$dir/home"; FIX_RUN="$dir/run"; FIX_TMP="$dir/tmp"; FIX_KEY="$dir/keys/key.txt"
  mkdir -p "$repo/scripts" "$repo/group_vars/all" "$repo/secrets" "$repo/notes" \
           "$FIX_HOME" "$FIX_RUN" "$FIX_TMP" "$dir/keys" "$dir/plain"
  chmod 700 "$FIX_RUN"
  local src="${FIX_SRC_ROOT:?}"
  for f in deploy hermes_secrets.py hermes_redact.py hermes_bootstrap.py generate-env.py audit_rules.py public-readiness-audit.py; do
    cp "$src/scripts/$f" "$repo/scripts/$f"
  done
  chmod +x "$repo/scripts/deploy" "$repo/scripts/public-readiness-audit.py"

  cat > "$repo/group_vars/all/secrets.yml" <<'M'
secrets_manifest:
  fix_audit_secret:
    env: FIX_AUDIT_SECRET
    required: true
M
  cat > "$repo/scripts/registered-scripts.conf" <<'C'
audit    scripts/public-readiness-audit.py
C
  cat > "$repo/README.md" <<'R'
# Fixture repository

Used only by tests/check-public-readiness-audit.sh. Nothing in this repository is real.
R

  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Fixture Bot"
  git -C "$repo" config user.email "fixture-bot@example.invalid"

  if [[ "$mode" == dirty ]]; then
    printf 'a secret lives in this tracked file: %s\n' "$AUDIT_CANARY_SECRET" > "$repo/notes/tree-secret.txt"
    printf 'an extra term lives in this tracked file: %s\n' "$AUDIT_CANARY_EXTRA" > "$repo/notes/extra-term.txt"
    printf 'the resolved target host address lives here: 127.0.0.1\n' > "$repo/notes/host-address.txt"
    python3 - "$AUDIT_CANARY_SECRET" > "$repo/notes/encoded.txt" <<'PY'
import json
import sys
import urllib.parse
value = sys.argv[1]
print(json.dumps(value)[1:-1])
print(urllib.parse.quote(value.encode("utf-8"), safe=""))
PY
    cat > "$repo/notes/generic-shapes.txt" <<EOF
$AUDIT_CANARY_GITHUB_TOKEN
$AUDIT_CANARY_AGE_KEY
$AUDIT_CANARY_PRIVATE_KEY_HEADER
$AUDIT_CANARY_TAILSCALE_KEY
EOF
    printf '%s\n' "$AUDIT_CANARY_CGNAT" > "$repo/notes/cgnat.txt"
    printf '100.64.0.0/10\n' > "$repo/notes/cgnat-functional.txt"
  fi

  git -C "$repo" add -A
  git -C "$repo" commit -q -m "init fixture"

  if [[ "$mode" == dirty ]]; then
    printf 'a secret that will be removed: %s\n' "$AUDIT_CANARY_HISTORY" > "$repo/notes/history-only-secret.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "add a secret that will be removed"
    git -C "$repo" rm -q notes/history-only-secret.txt
    git -C "$repo" commit -q -m "remove the secret (still in history)"

    # A binary blob carrying the git-crypt key header, on a side branch NEVER merged to main — proves
    # the scan reaches every ref, not just the current branch, and that it is binary-safe.
    git -C "$repo" branch side-branch
    git -C "$repo" checkout -q side-branch
    python3 -c "import sys; sys.stdout.buffer.write(b'\x00GITCRYPTKEY' + b'\x00\x00\x00\x02' + bytes(range(256)))" > "$repo/notes/old.key"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "add the dead git-crypt key (side branch only, never merged)"
    git -C "$repo" checkout -q main

    git -C "$repo" commit -q --allow-empty -m "commit message canary: $AUDIT_CANARY_COMMIT_MSG"

    GIT_AUTHOR_NAME="$AUDIT_CANARY_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUDIT_CANARY_AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$AUDIT_CANARY_COMMITTER_NAME" GIT_COMMITTER_EMAIL="$AUDIT_CANARY_COMMITTER_EMAIL" \
      git -C "$repo" commit -q --allow-empty -m "author/committer metadata canary"
  fi

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
  if [[ "$mode" == dirty ]]; then
    local extras="$AUDIT_CANARY_EXTRA,$AUDIT_CANARY_HISTORY,$AUDIT_CANARY_COMMIT_MSG,$AUDIT_CANARY_AUTHOR_NAME,$AUDIT_CANARY_AUTHOR_EMAIL,$AUDIT_CANARY_COMMITTER_NAME,$AUDIT_CANARY_COMMITTER_EMAIL"
    printf 'TARGET_HOST=localhost\nFIX_AUDIT_SECRET=%s\nAUDIT_EXTRA_TERMS=%s\n' "$AUDIT_CANARY_SECRET" "$extras" > "$store"
  else
    printf 'TARGET_HOST=localhost\nFIX_AUDIT_SECRET=clean-fixture-secret-value\n' > "$store"
  fi
  ( cd "$repo" && sops encrypt --filename-override secrets/secrets.enc.env --input-type dotenv --output-type dotenv "$store" > "$repo/secrets/secrets.enc.env" )
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "add the encrypted store"
}

audit_deploy() {   # audit_deploy [args...] -> $OUT, $RC
  set +e
  OUT="$(cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" \
        HERMES_SECRETS_KEY_FILE="$FIX_KEY" "$FIX_REPO/scripts/deploy" "$@" 2>&1)"
  RC=$?
  set -e
}

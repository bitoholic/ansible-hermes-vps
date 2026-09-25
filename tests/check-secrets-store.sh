#!/usr/bin/env bash
# Epic 22 ticket #03 guard: the structural guard for the encrypted secrets store (scripts/check_secrets_store.py).
#
# 1. The REAL repository passes (today: neither .sops.yaml nor a store, so only the store-independent checks apply).
# 2. Negative fixtures, one per failure, each in a throwaway git repository with a throwaway age key: a cleartext value,
#    a missing required name, an undeclared extra name, a tracked plaintext-secrets-looking file (by name and by content),
#    a tracked or un-ignored .env, a store whose SOPS metadata was stripped, a weakened .sops.yaml, and a store deleted
#    while the recipient configuration remains — plus positive cases: an absent OPTIONAL name and a declared extra pass,
#    and with neither .sops.yaml nor a store only the store-independent checks apply.
# 3. The guard needs no key (it runs with no key file and no key environment).
#
# What this CANNOT verify: that the ciphertext decrypts (needs a key: the deploy wrapper's preflight), or history.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
FIX_SRC_ROOT="$ROOT_DIR"
# shellcheck source=tests/support/deploy-fixture.sh
source tests/support/deploy-fixture.sh
fail() { echo "FAIL: $*" >&2; [[ -n "${OUT:-}" ]] && { echo "--- output ---" >&2; echo "$OUT" >&2; }; exit 1; }
for tool in sops age age-keygen git python3; do command -v "$tool" >/dev/null || { echo "FAIL: $tool is not installed" >&2; exit 1; }; done
export PYTHONDONTWRITEBYTECODE=1
echo "== secrets store structural guard (epic 22 #03) =="

python3 scripts/check_secrets_store.py >/dev/null || fail "the real repository must pass the structural guard"
echo "the real repository passes (no .sops.yaml and no store yet: store-independent checks only)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
make_fixture "$T"
G() {  # G: run the guard inside the fixture with NO key and NO key environment -> $OUT, $RC
  set +e
  OUT="$(cd "$FIX_REPO" && env -i PATH="$PATH" HOME="$FIX_HOME" python3 scripts/check_secrets_store.py 2>&1)"; RC=$?
  set -e
}
expect_ok()   { G; [[ $RC -eq 0 ]] || fail "$1: the guard must pass (rc=$RC)"; }
expect_fail() { G; [[ $RC -eq 1 ]] || fail "$1: the guard must FAIL with 1 (rc=$RC)"; grep -q -- "$2" <<<"$OUT" || fail "$1: failed but did not report '$2'"; }

# a fixture repository: the deployment fixture plus git, with .env ignored
( cd "$FIX_REPO" && git init -q . && git config user.email t@example.invalid && git config user.name t \
  && printf '.env\n' > .gitignore && git add -A && git commit -q -m fixture )
reset_repo() { ( cd "$FIX_REPO" && git checkout -q -- . && git clean -fdq -e 'x' ); }
new_store() {  # new_store <dotenv-text-file> : encrypt it as the store for the fixture key
  fx_encrypt "$1" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
}
fx_full_names="TARGET_HOST FIX_TOKEN FIX_DOMAIN FIX_UNICODE FIX_SHORT FIX_SPECIAL FIX_CONTAINER"
mk_plain() {  # mk_plain <file> NAME[=value]... -> a dotenv with those names (value defaults to a throwaway)
  : > "$1"; shift 2>/dev/null || true
}

expect_ok "a clean fixture (store, config, .env ignored)"
echo "clean fixture passes"

# --- the name-set rule -------------------------------------------------------------------------------------
# an absent OPTIONAL name and a declared extra (AUDIT_EXTRA_TERMS) both pass
{ for n in $fx_full_names; do echo "$n=value-$n"; done; echo "AUDIT_EXTRA_TERMS=a,b"; } > "$T/plain/n1.env"
new_store "$T/plain/n1.env"; expect_ok "optional names absent and a declared extra present"
# a missing REQUIRED name
{ for n in $fx_full_names; do [[ $n == FIX_TOKEN ]] || echo "$n=value-$n"; done; } > "$T/plain/n2.env"
new_store "$T/plain/n2.env"; expect_fail "a missing required name" 'required names missing from the store (by name): FIX_TOKEN'
! grep -q 'value-FIX' <<<"$OUT" || fail "the guard printed a value"
# an undeclared extra name
{ for n in $fx_full_names; do echo "$n=value-$n"; done; echo "SOMETHING_ELSE=x"; } > "$T/plain/n3.env"
new_store "$T/plain/n3.env"; expect_fail "an undeclared extra name" 'SOMETHING_ELSE'

# --- genuine encryption ------------------------------------------------------------------------------------
{ for n in $fx_full_names; do echo "$n=value-$n"; done; } > "$T/plain/ok.env"; new_store "$T/plain/ok.env"; expect_ok "a valid store"
cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.good"
sed -i -E 's/^(FIX_TOKEN)=ENC\[.*$/\1=cleartext-value-here/' "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "a cleartext value" 'value of FIX_TOKEN is not encrypted'
! grep -q 'cleartext-value-here' <<<"$OUT" || fail "the guard printed a cleartext value"
cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"
{ for n in $fx_full_names; do echo "$n=value-$n"; done; echo "EXTRA_unencrypted=plain"; } > "$T/plain/u.env"
cp "$T/store.good" "$T/store.keep"; ( cd "$T/plain" && sops encrypt --age "$FIX_PUB" --input-type dotenv --output-type dotenv u.env > "$FIX_REPO/secrets/secrets.enc.env" )
expect_fail "a name ending in _unencrypted (SOPS leaves such values in cleartext)" 'EXTRA_unencrypted'
cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"
grep -v '^sops_mac=' "$T/store.good" > "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "a store with its SOPS metadata stripped" 'sops_mac missing'
printf 'A_PLAIN_FILE=nothing here\n' > "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "a file that is not a SOPS store at all" 'carries no SOPS metadata'
cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"
{ cat "$T/store.good"; grep '^FIX_TOKEN=' "$T/store.good"; } > "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "a duplicated name" 'FIX_TOKEN appears more than once'
cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"
expect_ok "the good store again"

# --- the derived mandatory state -----------------------------------------------------------------------------
rm "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "the store deleted while .sops.yaml remains" 'encrypted store secrets/secrets.enc.env is missing'
rm "$FIX_REPO/.sops.yaml"
expect_ok "neither .sops.yaml nor a store (a fresh public export): only the store-independent checks apply"
cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "a store without .sops.yaml" 'no .sops.yaml'
rm "$FIX_REPO/secrets/secrets.enc.env"
reset_repo
new_store "$T/plain/ok.env"

# --- .sops.yaml -----------------------------------------------------------------------------------------------
cp "$FIX_REPO/.sops.yaml" "$T/sops.good"
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    unencrypted_suffix: _x\n    key_groups:\n      - age:\n          - %s\n' "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml weakening value encryption" 'unencrypted_suffix'
printf 'creation_rules:\n  - path_regex: ^other/thing\\.env$\n    key_groups:\n      - age:\n          - %s\n' "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml not scoped to the store's path" "no rule whose path_regex matches"
printf 'creation_rules:\n  - key_groups:\n      - age:\n          - %s\n' "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml without a path_regex" 'no path_regex'
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    key_groups:\n      - age: []\n' > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml with no recipient" 'lists no age recipient'
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    key_groups:\n      - age:\n          - not-an-age-key\n' > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml with a non-age recipient" 'not an age public key'
cp "$T/sops.good" "$FIX_REPO/.sops.yaml"
expect_ok "the good configuration again"

# --- the tripwire and stray plaintext files (store-independent) ---------------------------------------------------
( cd "$FIX_REPO" && printf '' > .gitignore ); expect_fail ".env not ignored" '.env is not git-ignored'
( cd "$FIX_REPO" && printf '.env\n' > .gitignore )
( cd "$FIX_REPO" && printf 'x=1\n' > .env && git add -f .env ); expect_fail ".env tracked" '.env is tracked by git'
( cd "$FIX_REPO" && git rm -q --cached -f .env && rm .env )
( cd "$FIX_REPO" && printf 'a=1\n' > backup.env && git add backup.env ); expect_fail "a tracked *.env file" 'backup.env: a file with the name of a plaintext secrets file'
( cd "$FIX_REPO" && git rm -q --cached -f backup.env && rm backup.env )
( cd "$FIX_REPO" && printf 'export FIX_TOKEN=Kj83hd92Lx\nFIX_DOMAIN=my-real.domain.tld\nFIX_UNICODE="qW9zXc7Vb2"\n' > notes.txt && git add notes.txt )
expect_fail "a tracked file whose CONTENT looks like a plaintext secrets file" 'notes.txt: looks like a plaintext secrets file'
! grep -qE 'Kj83hd92Lx|my-real' <<<"$OUT" || fail "the guard printed a value from a plaintext-looking file"
( cd "$FIX_REPO" && git rm -q --cached -f notes.txt && rm notes.txt )
# the names-only template, fixtures with stand-in values and documentation mentioning names are NOT plaintext secrets files
( cd "$FIX_REPO" && printf 'export FIX_TOKEN=""  # required\nexport FIX_DOMAIN=""\nexport FIX_UNICODE=""\nexport FIX_SHORT=""\n' > .env.template \
  && printf 'export FIX_TOKEN=WIKI_KEY\nexport FIX_DOMAIN=DOMAIN_X\nexport FIX_UNICODE=SOME_HASH\n' > fixture.sh \
  && printf 'set FIX_TOKEN=<your token> and FIX_DOMAIN=example.org\n' > README.md && git add -A )
expect_ok "the template, fixture-style values and documentation"
( cd "$FIX_REPO" && printf 'FIX_TOKEN=Kj83hd92Lx\nFIX_DOMAIN=Vb2mN7qW9z\n' > two.txt && git add two.txt )
expect_ok "only two names assigned (below the threshold)"

# --- hiding places for plaintext inside a store that otherwise looks right (review round 1) ----------------------------
restore_store() { cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"; }
new_store "$T/plain/ok.env"; cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.good"; expect_ok "the good store"
mutate_store() {  # mutate_store <label> <expected message> <line to append | ->  [sed expression]
  restore_store
  if [[ "$3" != "-" ]]; then printf '%s\n' "$3" >> "$FIX_REPO/secrets/secrets.enc.env"; fi
  if [[ -n "${4:-}" ]]; then sed -i -E "$4" "$FIX_REPO/secrets/secrets.enc.env"; fi
  expect_fail "$1" "$2"
  ! grep -qE 'hunter2|my-plain-secret' <<<"$OUT" || fail "$1: the guard printed the plaintext"
  restore_store
}
mutate_store "a plaintext value under a sops_-prefixed name (SOPS ignores such names)" 'sops_HUNTER is not a SOPS metadata name' 'sops_HUNTER=my-plain-secret'
mutate_store "plaintext dressed as ciphertext" 'value of FIX_TOKEN is not encrypted' - 's/^FIX_TOKEN=.*/FIX_TOKEN=ENC[AES256_GCM,data:hunter2secret,iv:AAAA,tag:BBBB,type:str]/'
mutate_store "a plaintext comment line" 'not a NAME=value line' '#ENC[AES256_GCM,token=hunter2-plain-secret]'
mutate_store "a stray plaintext line" 'not a NAME=value line' '# password is hunter2'
mutate_store "an unknown ciphertext type" 'value of FIX_TOKEN is not encrypted' - 's/^(FIX_TOKEN=ENC.*),type:str\]/\1,type:zzz]/'
mutate_store "SOPS metadata: version removed" 'sops_version missing' - '/^sops_version=/d'
mutate_store "SOPS metadata: last-modified removed" 'sops_lastmodified missing' - '/^sops_lastmodified=/d'
mutate_store "SOPS metadata: the age data key removed" 'carries no age recipient entry' - '/^sops_age__list_0__map_enc=/d'
mutate_store "SOPS metadata: the recipient removed" 'names no age recipient' - '/^sops_age__list_0__map_recipient=/d'
mutate_store "SOPS metadata: a non-default unencrypted suffix" 'sops_unencrypted_suffix has a non-default value' - 's/^sops_unencrypted_suffix=.*/sops_unencrypted_suffix=_x/'
mutate_store "SOPS metadata: mac_only_encrypted" 'sops_mac_only_encrypted is not a SOPS metadata name' 'sops_mac_only_encrypted=true'
mutate_store "SOPS metadata: a recipient that is not an age key" 'is not an age public key' - 's/^(sops_age__list_0__map_recipient)=.*/\1=nobody/'
# a real store with an EMPTY optional value (SOPS leaves an empty value as an empty string) passes
{ for n in $fx_full_names; do echo "$n=value-$n"; done; echo "AUDIT_EXTRA_TERMS="; } > "$T/plain/empty.env"; new_store "$T/plain/empty.env"
expect_ok "an empty optional value"
{ for n in $fx_full_names; do [[ $n == TARGET_HOST ]] || echo "$n=value-$n"; done; } > "$T/plain/nohost.env"; new_store "$T/plain/nohost.env"
expect_fail "a store without the required declared extra TARGET_HOST" 'required names missing from the store (by name): TARGET_HOST'
new_store "$T/plain/ok.env"; cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.good"

# --- more plaintext-file names and shapes ---------------------------------------------------------------------------
for f in .envrc .env.local sub/.env .ENV prod.ENV; do
  ( cd "$FIX_REPO" && mkdir -p "$(dirname "$f")" && printf 'a=1\n' > "$f" && git add -f "$f" ); expect_fail "a tracked $f" "$f: a file "  # (either wording: named .env, or the name of a plaintext secrets file)
  ( cd "$FIX_REPO" && git rm -q --cached -f "$f" && rm -f "$f" )
done
( cd "$FIX_REPO" && printf 'a=1\n' > secrets.env ); expect_fail "an UNTRACKED, un-ignored *.env (git add -A would commit it)" 'secrets.env: a file with the name of a plaintext secrets file'
rm -f "$FIX_REPO/secrets.env"
( cd "$FIX_REPO" && printf 'x\n' > .env.j2 && git add .env.j2 ); expect_ok "a .env.j2 template"
( cd "$FIX_REPO" && git rm -q --cached -f .env.j2 && rm .env.j2 )
( cd "$FIX_REPO" && printf 'FIX_TOKEN: Kj83hd92Lx\nFIX_DOMAIN: Vb2mN7qW9z\nFIX_UNICODE: qW9zXc7Vb2\n' > vars.yml && git add vars.yml ); expect_fail "a YAML-style plaintext file" 'vars.yml: looks like a plaintext secrets file'
( cd "$FIX_REPO" && printf '{"FIX_TOKEN": "Kj83hd92Lx",\n "FIX_DOMAIN": "Vb2mN7qW9z",\n "FIX_UNICODE": "qW9zXc7Vb2"}\n' > vars.yml && git add vars.yml ); expect_fail "a JSON plaintext file" 'vars.yml'
( cd "$FIX_REPO" && printf '\xef\xbb\xbfFIX_TOKEN = Kj83hd92Lx\nFIX_DOMAIN = Vb2mN7qW9z\n- FIX_UNICODE=qW9zXc7Vb2\n' > vars.yml && git add vars.yml ); expect_fail "a BOM-prefixed plaintext file with spaced and list forms" 'vars.yml'
( cd "$FIX_REPO" && git rm -q --cached -f vars.yml && rm vars.yml )
expect_ok "no stray files left"
# a store that is git-ignored would never be committed
( cd "$FIX_REPO" && git rm -q --cached -f secrets/secrets.enc.env && printf '.env\nsecrets/\n' > .gitignore ); expect_fail "a git-ignored store" 'is git-ignored'
( cd "$FIX_REPO" && printf '.env\n' > .gitignore && git add secrets/secrets.enc.env )
# .sops.yaml forms
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    mac_only_encrypted: true\n    key_groups:\n      - age:\n          - %s\n' "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml with mac_only_encrypted" 'mac_only_encrypted'
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    key_groups: [null]\n' > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml with a null key group (must not crash)" 'lists no age recipient'
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    age: %s\n' "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_ok ".sops.yaml with a comma-separated string of recipients"
cp "$T/sops.good" "$FIX_REPO/.sops.yaml"

# --- the guard needs no key --------------------------------------------------------------------------------------
[[ ! -e "$FIX_HOME/.config/sops" ]] || fail "test setup: a key file exists in the fixture HOME"
echo "structural guard OK"

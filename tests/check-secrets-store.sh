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
mutate_store "SOPS metadata: the age data key removed" 'age slot 0 is unpaired' - '/^sops_age__list_0__map_enc=/d'
mutate_store "SOPS metadata: the recipient removed" 'age slot 0 is unpaired' - '/^sops_age__list_0__map_recipient=/d'
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

# --- review round 2: more hiding places, real-sops shapes -------------------------------------------------------------------
mutate_store "plaintext appended to sops_version" 'sops_version is not a version' - 's/^sops_version=.*/sops_version=3.13.3+HUNTER2PLAINSECRET/'
mutate_store "plaintext appended to sops_lastmodified" 'sops_lastmodified is not a timestamp' - 's/^(sops_lastmodified=.*)$/\1+HUNTER2/'
mutate_store "a recipient with a bad bech32 checksum" 'is not an age public key' - 's/^(sops_age__list_0__map_recipient=age1)q/\1p/; t; s/^(sops_age__list_0__map_recipient=age1)[^q]/\1q/'
mutate_store "a plaintext age recipient lookalike" 'is not an age public key' - 's/^(sops_age__list_0__map_recipient)=.*/\1=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq/'
mutate_store "the age data key with a plaintext tail" 'is not an age-encrypted data key' - 's/^(sops_age__list_0__map_enc=.*)$/\1HUNTER2 plain text/'
mutate_store "multi-group (Shamir) metadata" 'multi-group / Shamir stores are not used' 'sops_shamir_threshold=2'
# a store encrypted to TWO recipients (workstation + break-glass) — with comments, a bare '#', an empty value — passes
age-keygen -o "$T/keys/bg.txt" >/dev/null 2>&1; BG_PUB="$(age-keygen -y "$T/keys/bg.txt")"
{ printf '#\n# a comment\n'; for n in $fx_full_names; do echo "$n=value-$n"; done; echo "AUDIT_EXTRA_TERMS="; } > "$T/plain/two.env"
fx_encrypt "$T/plain/two.env" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB" "$BG_PUB"
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    key_groups:\n      - age:\n          - %s\n          - %s\n' "$FIX_PUB" "$BG_PUB" > "$FIX_REPO/.sops.yaml"
expect_ok "a REAL two-recipient store with comments, a bare # and an empty value"
cp "$FIX_REPO/.sops.yaml" "$T/sops.two"; cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.two"
# the second recipient's data key hidden plaintext: sops still decrypts with the first, the guard must not
sed -i -E 's/^(sops_age__list_1__map_enc)=.*/\1=-----BEGIN AGE ENCRYPTED FILE-----\\nHUNTER2 plain text\\n-----END AGE ENCRYPTED FILE-----\\n/' "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "plaintext in an unused recipient's data key" 'sops_age__list_1__map_enc is not an age-encrypted data key'
new_store "$T/plain/ok.env"; cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.good"


# the store's recipients must be EXACTLY .sops.yaml's for the path: a removed recipient still in the store (updatekeys not run)...
cp "$T/store.two" "$FIX_REPO/secrets/secrets.enc.env"; cp "$T/sops.good" "$FIX_REPO/.sops.yaml"
expect_fail "a recipient in the store that .sops.yaml does not list (or was removed from it: updatekeys not run)" "store's recipients differ from .sops.yaml's"
# ...and a recipient in .sops.yaml the store was never re-encrypted for
new_store "$T/plain/ok.env"; cp "$T/sops.two" "$FIX_REPO/.sops.yaml"
expect_fail "a recipient in .sops.yaml that the store is not encrypted for" "store's recipients differ from .sops.yaml's"
# ...and a COMPUTED recipient (valid bech32 checksum, ~50 free characters of text) hidden in an unused slot
cp "$T/store.two" "$FIX_REPO/secrets/secrets.enc.env"
python3 - "$FIX_REPO/secrets/secrets.enc.env" <<'E'
import re, sys
CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(v):
    gen = (0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3); c = 1
    for x in v:
        top = c >> 25; c = (c & 0x1ffffff) << 5 ^ x
        for i in range(5): c ^= gen[i] if (top >> i) & 1 else 0
    return c
hrp = "age"; body = ("hunter2" * 8)[:52]
data = [CH.index(ch) for ch in body]
expand = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
mod = polymod(expand + data + [0] * 6) ^ 1
key = "age1" + body + "".join(CH[(mod >> 5 * (5 - i)) & 31] for i in range(6))
t = open(sys.argv[1]).read()
t = re.sub(r"(?m)^(sops_age__list_1__map_recipient)=.*$", lambda m: m.group(1) + "=" + key, t)
open(sys.argv[1], "w").write(t)
E
cp "$T/sops.two" "$FIX_REPO/.sops.yaml"
expect_fail "a computed, checksum-valid recipient hiding text in the second slot" "store's recipients differ from .sops.yaml's"
! grep -q 'hunter2' <<<"$OUT" || fail "the guard printed the hidden text"
new_store "$T/plain/ok.env"; cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.good"; cp "$T/sops.good" "$FIX_REPO/.sops.yaml"

# --- trailing plaintext after ciphertext (sops' own regex has no end anchor: it decrypts with rc 0) ---------------------------
mutate_store "trailing plaintext after a value's ciphertext" 'value of FIX_TOKEN is not encrypted' - 's/^(FIX_TOKEN=ENC\[.*\])$/\1hunter2plain/'
mutate_store "trailing plaintext after sops_mac" 'sops_mac is not a SOPS MAC' - 's/^(sops_mac=ENC\[.*\])$/\1hunter2plain/'
mutate_store "sops_mac that is not ciphertext at all" 'sops_mac is not a SOPS MAC' - 's/^sops_mac=.*/sops_mac=hunter2plain/'
mutate_store "trailing plaintext after a comment's ciphertext" 'not a NAME=value line' '#ENC[AES256_GCM,data:aGVsbG8=,iv:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:comment]hunter2plain'
# recipient slots: unpaired, duplicated, non-canonical and oversized slots hide text SOPS never reads (a single-recipient
# store decrypts with slot 0 alone)
ARM='-----BEGIN AGE ENCRYPTED FILE-----\nQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=\n-----END AGE ENCRYPTED FILE-----\n'
mutate_store "an extra data-key slot with no recipient line" 'age slot 1 is unpaired' "sops_age__list_1__map_enc=$ARM"
RECIP0="$(grep '^sops_age__list_0__map_recipient=' "$FIX_REPO/secrets/secrets.enc.env" | cut -d= -f2)"
mutate_store "a duplicated recipient with its own hidden data key" 'names the same age recipient more than once' "sops_age__list_1__map_recipient=$RECIP0
sops_age__list_1__map_enc=$ARM"
mutate_store "a non-canonical slot number" 'is not a SOPS metadata name' "sops_age__list_01__map_enc=$ARM"
mutate_store "a slot numbering gap" 'not numbered 0..' "sops_age__list_2__map_recipient=$RECIP0
sops_age__list_2__map_enc=$ARM"
mutate_store "a repeated metadata line" 'metadata name sops_version appears more than once' "sops_version=3.13.3"
BIG='-----BEGIN AGE ENCRYPTED FILE-----\n'; for i in $(seq 1 12); do BIG="${BIG}QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=\n"; done; BIG="${BIG}-----END AGE ENCRYPTED FILE-----\n"
# (sed's replacement text reinterprets a literal \n as a real newline, which would split this across physical lines and
# get rejected for the WRONG reason — a duplicate NAME= line rather than the armour-length bound; write it directly)
restore_store
python3 - "$FIX_REPO/secrets/secrets.enc.env" <<'E'
import re, sys
path = sys.argv[1]
big = "-----BEGIN AGE ENCRYPTED FILE-----\n" + "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=\n" * 14 + "-----END AGE ENCRYPTED FILE-----\n"
text = open(path).read()
text = re.sub(r"(?m)^sops_age__list_0__map_enc=.*$", "sops_age__list_0__map_enc=" + big, text)
open(path, "w").write(text)
E
expect_fail "an oversized age data key (room to hide a blob)" 'sops_age__list_0__map_enc is not an age-encrypted data key'
! grep -qE 'hunter2|my-plain-secret' <<<"$OUT" || fail "the guard printed the plaintext"
restore_store
# SOPS uses only the FIRST creation rule that matches the store's path (and key_groups over age): the guard must model that
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    key_groups:\n      - age:\n          - %s\n  - path_regex: .*\\.env$\n    key_groups:\n      - age:\n          - %s\n' "$FIX_PUB" "$BG_PUB" > "$FIX_REPO/.sops.yaml"
expect_ok "a specific rule first and a wider rule second (the second is never used for the store)"
printf 'creation_rules:\n  - path_regex: .*\\.env$\n    key_groups:\n      - age:\n          - %s\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    key_groups:\n      - age:\n          - %s\n' "$BG_PUB" "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_fail "a wide rule FIRST wins: the store must match ITS recipients" "store's recipients differ from .sops.yaml's"
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    age: %s\n    key_groups:\n      - age:\n          - %s\n' "$BG_PUB" "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_ok "key_groups win over age in one rule"
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    age: %s,%s\n' "$FIX_PUB" "$BG_PUB" > "$FIX_REPO/.sops.yaml"
cp "$T/store.two" "$FIX_REPO/secrets/secrets.enc.env"
expect_ok "a comma-separated string of TWO recipients against a two-recipient store"
printf 'creation_rules:\n  - notamapping\n' > "$FIX_REPO/.sops.yaml"
expect_fail ".sops.yaml with a rule that is not a mapping" 'is not a mapping'
cp "$T/sops.good" "$FIX_REPO/.sops.yaml"; cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"
# every value-weakening key in .sops.yaml is refused
for key in unencrypted_suffix unencrypted_regex unencrypted_comment_regex encrypted_suffix encrypted_regex encrypted_comment_regex mac_only_encrypted; do
  printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    %s: x\n    key_groups:\n      - age:\n          - %s\n' "$key" "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
  expect_fail ".sops.yaml setting $key" "$key"
done
cp "$T/sops.good" "$FIX_REPO/.sops.yaml"
# an EMPTY value for a required name, and a symlinked store
{ for n in $fx_full_names; do if [[ $n == FIX_TOKEN ]]; then echo "$n="; else echo "$n=value-$n"; fi; done; } > "$T/plain/emptyreq.env"; new_store "$T/plain/emptyreq.env"
expect_fail "an empty value for a required name" 'the value of the required name FIX_TOKEN is empty'
new_store "$T/plain/ok.env"; cp "$FIX_REPO/secrets/secrets.enc.env" "$T/store.good"
cp "$T/store.good" "$T/store.target"; rm "$FIX_REPO/secrets/secrets.enc.env"; ln -s "$T/store.target" "$FIX_REPO/secrets/secrets.enc.env"
expect_fail "a symlinked store" 'is a symlink'
rm "$FIX_REPO/secrets/secrets.enc.env"; cp "$T/store.good" "$FIX_REPO/secrets/secrets.enc.env"
# a long run of spaces after a manifest name must not make the content scan quadratic
( cd "$FIX_REPO" && { printf 'FIX_TOKEN=a'; head -c 300000 /dev/zero | tr '\0' ' '; printf '\n'; } > spaces.txt && git add spaces.txt )
start=$SECONDS; expect_ok "a file with a long run of spaces after a name"; (( SECONDS - start < 8 )) || fail "the content scan is slow on a long run of spaces ($((SECONDS - start)) s)"
( cd "$FIX_REPO" && git rm -q --cached -f spaces.txt && rm spaces.txt )

# --- .sops.yaml semantics -----------------------------------------------------------------------------------------------
printf 'creation_rules:\n  - path_regex: secrets/secrets\\.enc\\.env$\n    key_groups:\n      - age:\n          - %s\n' "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_ok ".sops.yaml path_regex not anchored at the start (SOPS uses a search, not a match)"
printf 'creation_rules:\n  - path_regex: ^secrets/secrets\\.enc\\.env$\n    age:\n      - %s\n' "$FIX_PUB" > "$FIX_REPO/.sops.yaml"
expect_ok ".sops.yaml with age as a YAML list"
cp "$T/sops.good" "$FIX_REPO/.sops.yaml"

# --- user-global ignores, symlinks, key material, more content forms -----------------------------------------------------
printf '[core]\n\texcludesFile = %s/global_ignore\n' "$FIX_HOME" > "$FIX_HOME/.gitconfig"; printf '.env\n' > "$FIX_HOME/global_ignore"
( cd "$FIX_REPO" && printf '' > .gitignore )
expect_fail ".env ignored only by a USER-GLOBAL ignore (a fresh clone would not ignore it)" '.env is not git-ignored'
( cd "$FIX_REPO" && printf '.env\n' > .gitignore ); rm -f "$FIX_HOME/.gitconfig" "$FIX_HOME/global_ignore"
printf 'export FIX_TOKEN=Kj83hd92Lx\nexport FIX_DOMAIN=Vb2mN7qW9z\nexport FIX_UNICODE=qW9zXc7Vb2\n' > "$T/outside-secrets.txt"
( cd "$FIX_REPO" && ln -s "$T/outside-secrets.txt" link.txt && git add link.txt )
expect_ok "a tracked symlink whose TARGET holds plaintext-looking names (the target must never be read)"
( cd "$FIX_REPO" && git rm -q --cached -f link.txt && rm link.txt )
( cd "$FIX_REPO" && printf 'declare -x FIX_TOKEN="Kj83hd92Lx"\ndeclare -x FIX_DOMAIN="Vb2mN7qW9z"\ndeclare -x FIX_UNICODE="qW9zXc7Vb2"\n' > envdump.txt && git add envdump.txt )
expect_fail "a bash 'export -p' style dump" 'envdump.txt: looks like a plaintext secrets file'
( cd "$FIX_REPO" && git rm -q --cached -f envdump.txt && rm envdump.txt )
( cd "$FIX_REPO" && { printf 'identity: '; head -c 20000 "$FIX_KEY" | grep AGE-SECRET-KEY; } > id.txt && git add id.txt )
expect_fail "an age identity (private key) in a tracked file" 'id.txt: contains private key material'
! grep -q 'AGE-SECRET-KEY-1' <<<"$OUT" || fail "the guard printed the private key"
( cd "$FIX_REPO" && git rm -q --cached -f id.txt && rm id.txt )
( cd "$FIX_REPO" && printf -- '-----BEGIN %s PRIVATE KEY-----\nMIIB\n-----END %s PRIVATE KEY-----\n' RSA RSA > key.pem && git add key.pem )
expect_fail "a PEM private key in a tracked file" 'key.pem: contains private key material'
( cd "$FIX_REPO" && git rm -q --cached -f key.pem && rm key.pem )
expect_ok "no stray files left (round 2)"

# --- the guard needs no key --------------------------------------------------------------------------------------
[[ ! -e "$FIX_HOME/.config/sops" ]] || fail "test setup: a key file exists in the fixture HOME"

# --- a compiled-bytecode file planted in scripts/__pycache__ (gitignored, so `git diff` stays clean) must not be
# loaded in place of hermes_secrets.py's real source (epic 22 ticket #08's own review found this exact guard was
# present in scripts/deploy but missing from scripts/secrets and scripts/check_secrets_store.py) ------------------
mkdir -p "$FIX_REPO/scripts/__pycache__"
printf 'open("%s/store-pyc-leak", "a").write("EVIL MODULE LOADED")\n' "$T" > "$T/evil_secrets.py"
python3 - "$T/evil_secrets.py" "$FIX_REPO/scripts/hermes_secrets.py" <<'E'
import importlib.util, py_compile, sys
target = importlib.util.cache_from_source(sys.argv[2])
py_compile.compile(sys.argv[1], cfile=target, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)
E
expect_ok "planted bytecode in scripts/__pycache__ must not be loaded in place of hermes_secrets.py"
[[ ! -e "$T/store-pyc-leak" ]] || fail "planted bytecode in scripts/__pycache__ was loaded in place of hermes_secrets.py"
rm -rf "$FIX_REPO/scripts/__pycache__"

echo "structural guard OK"

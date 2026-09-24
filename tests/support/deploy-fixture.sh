# Sourced by the deploy-wrapper tests. Builds a throwaway repository tree that contains a COPY of the wrapper,
# the real `secrets` resolver role, a fixture manifest and playbook, a throwaway age key and a fixture encrypted
# store holding canary values. No real key or secret is ever needed.
#
#   make_fixture DIR   -> creates DIR/{repo,home,run,tmp,keys}; sets FIX_REPO FIX_HOME FIX_RUN FIX_TMP FIX_KEY FIX_PUB
#   fx_deploy [args]   -> runs the fixture's wrapper copy from an unrelated cwd, with a confined environment;
#                         output in $OUT (stdout+stderr combined), status in $RC
#   fx_encrypt SRC_DOTENV DEST PUBKEY...  -> encrypt a dotenv file to DEST for the given age public keys
#
# Canary values (fixture only; not secrets):
CANARY_TOKEN='tok-9f8e7d6c5b4a3210'
CANARY_DOMAIN='fixture-domain.example'
CANARY_UNICODE='zażółć-gęślą-jaźń'
CANARY_SHORT='ab12'
CANARY_SPECIAL='p@ss w/ord&x=1%'
CANARY_CONTAINER="wrap-${CANARY_TOKEN}-wrap"    # contains another value
CANARY_OVERLAP='3210-overlap-zz'                 # overlaps the END of the token when the two are printed together
CANARY_LONGER="${CANARY_TOKEN}-longer"           # the token is a proper prefix of this value
CANARY_QUOTES="it's \"q\" ok"                     # repr() escapes the single quote
CANARY_TINY='abc'                                # below the redaction minimum (3 characters): NOT masked
CANARY_HOST='127.0.0.2'

fx_encrypt() {  # fx_encrypt SRC DEST PUBKEY...
  local src="$1" dest="$2"; shift 2
  local recips; recips="$(IFS=,; echo "$*")"
  # run from the source file's own directory: sops loads a .sops.yaml it finds from there upward, and even with
  # --age it then insists a creation rule matches the file
  ( cd "$(dirname "$src")" && sops encrypt --age "$recips" --input-type dotenv --output-type dotenv "$src" >"$dest" )
}

make_fixture() {
  local dir="$1" repo="$1/repo"
  FIX_REPO="$repo"; FIX_HOME="$dir/home"; FIX_RUN="$dir/run"; FIX_TMP="$dir/tmp"; FIX_KEY="$dir/keys/key.txt"
  mkdir -p "$repo/scripts" "$repo/group_vars/all" "$repo/roles/secrets/tasks" "$repo/secrets" "$FIX_HOME" "$FIX_RUN" "$FIX_TMP" "$dir/keys" "$dir/plain"
  chmod 700 "$FIX_RUN"
  local src="${FIX_SRC_ROOT:?}"
  for f in deploy hermes_secrets.py hermes_redact.py generate-env.py; do cp "$src/scripts/$f" "$repo/scripts/$f"; done
  chmod +x "$repo/scripts/deploy"
  cp "$src/roles/secrets/tasks/main.yml" "$repo/roles/secrets/tasks/main.yml"    # the REAL resolver
  cat > "$repo/group_vars/all/secrets.yml" <<'M'
secrets_manifest:
  fix_token:    { env: FIX_TOKEN,    required: true }
  fix_domain:   { env: FIX_DOMAIN,   required: true }
  fix_unicode:  { env: FIX_UNICODE,  required: true }
  fix_short:    { env: FIX_SHORT,    required: true }
  fix_special:   { env: FIX_SPECIAL,   required: true }
  fix_container: { env: FIX_CONTAINER, required: true }
  fix_tiny:      { env: FIX_TINY }
  fix_overlap:   { env: FIX_OVERLAP }
  fix_longer:    { env: FIX_LONGER }
  fix_quotes:    { env: FIX_QUOTES }
  fix_optional: { env: FIX_OPTIONAL, default: "dflt" }
M
  cat > "$repo/group_vars/all/conn.yml" <<'C'
ansible_connection: local
ansible_python_interpreter: "{{ ansible_playbook_python }}"
C
  cat > "$repo/ansible.cfg" <<'C'
[defaults]
roles_path = ./roles
retry_files_enabled = false
stdout_callback = default
deprecation_warnings = False
C
  cat > "$repo/scripts/registered-scripts.conf" <<'C'
show-env      scripts/fx-show-env.sh
exit-seven    scripts/fx-exit-seven.sh
missing-file  scripts/fx-not-there.sh
escape        ../outside.sh
split         scripts/fx-split.sh
tail          scripts/fx-tail.sh
tail-full     scripts/fx-tail-full.sh
kill-self     scripts/fx-kill-self.sh
not-exec      scripts/fx-not-exec.sh
link          scripts/fx-link.sh
sibling       ../repo-evil/x.sh
big-output    scripts/fx-big-output.sh
grandchild    scripts/fx-grandchild.sh
medium        scripts/fx-medium-output.sh
outerr        scripts/fx-outerr.sh
C
  cat > "$repo/scripts/fx-show-env.sh" <<'C'
#!/usr/bin/env bash
[[ "$FIX_TOKEN" == "tok-9f8e7d6c5b4a3210" && "$TARGET_HOST" == "127.0.0.2" ]] && echo "SCRIPT SAW THE STORE" || echo "SCRIPT DID NOT SEE THE STORE"
[[ -z "${SOPS_AGE_KEY_FILE:-}${SOPS_AGE_KEY:-}${HERMES_SECRETS_KEY_FILE:-}${SOPS_AGE_KEY_CMD:-}${HERMES_SECRETS_STORE:-}" ]] && echo "KEY SOURCE NOT EXPOSED" || echo "KEY SOURCE EXPOSED"
[[ -z "$(env | grep -E '^_?ANSIBLE_' || true)" ]] && echo "ANSIBLE SETTINGS CLEARED" || echo "ANSIBLE SETTINGS PASSED ON"
echo "SCRIPT-STDERR-LINE" >&2
echo "args: $*"
C
  printf '#!/usr/bin/env bash\nexit 7\n' > "$repo/scripts/fx-exit-seven.sh"
  # writes every secret value split at EVERY position across two separate writes (a pause between them forces two
  # reads), to stdout and to stderr, in plain and JSON-escaped forms — the redactor must find values that straddle chunks
  cat > "$repo/scripts/fx-split.sh" <<'SPLIT'
#!/usr/bin/env python3
import json, os, sys, time
values = [os.environ[n] for n in ("FIX_TOKEN", "FIX_UNICODE", "FIX_SPECIAL", "FIX_SHORT", "FIX_CONTAINER", "FIX_QUOTES")]
def emit(stream, data):
    stream.buffer.write(data); stream.buffer.flush()
for stream in (sys.stdout, sys.stderr):
    for value in values:
        for form in (value, json.dumps(value)[1:-1], repr(value)[1:-1]):
            raw = ("SPLIT[" + form + "]").encode()
            for cut in range(len(b"SPLIT[") , len(raw)):
                emit(stream, raw[:cut]); time.sleep(0.01); emit(stream, raw[cut:] + b"\n")
SPLIT
  # ends with the WHOLE token and no newline; the token is a proper prefix of another value, so it is held back and must be masked at exit
  printf '#!/usr/bin/env bash\nprintf "%%s" "$FIX_TOKEN"\n' > "$repo/scripts/fx-tail-full.sh"; chmod +x "$repo/scripts/fx-tail-full.sh"
  # ends WITHOUT a newline in the middle of what could be the start of a value: the held-back tail must be flushed at exit
  printf '#!/usr/bin/env bash\nprintf "END-%%s" "${FIX_TOKEN:0:3}"\n' > "$repo/scripts/fx-tail.sh"
  printf '#!/usr/bin/env bash\nkill -9 $$\n' > "$repo/scripts/fx-kill-self.sh"
  printf '#!/usr/bin/env bash\necho should-not-run\n' > "$repo/scripts/fx-not-exec.sh"
  chmod +x "$repo/scripts/fx-show-env.sh" "$repo/scripts/fx-exit-seven.sh" "$repo/scripts/fx-kill-self.sh" "$repo/scripts/fx-split.sh" "$repo/scripts/fx-tail.sh"
  ln -s ../../outside.sh "$repo/scripts/fx-link.sh"
  mkdir -p "$dir/repo-evil"; printf '#!/usr/bin/env bash\necho sibling-ran\n' > "$dir/repo-evil/x.sh"; chmod +x "$dir/repo-evil/x.sh"
  printf '#!/usr/bin/env bash\nhead -c 5000000 /dev/zero | tr "\\0" x\n' > "$repo/scripts/fx-big-output.sh"
  printf '#!/usr/bin/env bash\nhead -c 125000 /dev/zero | tr "\\0" x\necho\n' > "$repo/scripts/fx-medium-output.sh"; chmod +x "$repo/scripts/fx-medium-output.sh"
  printf '#!/usr/bin/env bash\nsleep 8 &\necho parent-done\nexit 0\n' > "$repo/scripts/fx-grandchild.sh"
  printf '#!/usr/bin/env bash\necho OUT-LINE\necho ERR-LINE >&2\n' > "$repo/scripts/fx-outerr.sh"
  chmod +x "$repo/scripts/fx-big-output.sh" "$repo/scripts/fx-grandchild.sh" "$repo/scripts/fx-outerr.sh"
  # a tiny collection in the USER's collections directory (where galaxy installs land): the wrapper's
  # ANSIBLE_HOME pin must not make it undiscoverable
  local coll="$FIX_HOME/.ansible/collections/ansible_collections/hermesfix/demo/plugins/modules"
  mkdir -p "$coll"
  cat > "$coll/hello.py" <<'PYM'
#!/usr/bin/python
from ansible.module_utils.basic import AnsibleModule
def main():
    AnsibleModule(argument_spec={}).exit_json(changed=False, msg="COLLECTION-FOUND")
main()
PYM
  printf '#!/usr/bin/env bash\necho escaped\n' > "$dir/outside.sh"; chmod +x "$dir/outside.sh"
  mkdir -p "$repo/templates"
  printf 'token={{ secrets.fix_token }}\nspecial={{ secrets.fix_special }}\nunicode={{ secrets.fix_unicode }}\nwrap={{ secrets.fix_container }}\n' > "$repo/templates/leak.j2"
  cat > "$repo/site.yml" <<Y
- name: fixture deployment
  hosts: all
  gather_facts: false
  roles:
    - role: secrets
      tags: [always]
  tasks:
    - name: Resolver received the fixture values
      ansible.builtin.assert:
        that:
          - secrets.fix_token == '$CANARY_TOKEN'
          - secrets.fix_domain == '$CANARY_DOMAIN'
          - secrets.fix_unicode == '$CANARY_UNICODE'
          - secrets.fix_short == '$CANARY_SHORT'
          - secrets.fix_special == '$CANARY_SPECIAL'
          - secrets.fix_container == '$CANARY_CONTAINER'
          - secrets.fix_tiny == '$CANARY_TINY'
          - secrets.fix_overlap == '$CANARY_OVERLAP'
          - secrets.fix_longer == '$CANARY_LONGER'
          - secrets.fix_optional == 'dflt'
        quiet: true
      tags: [always]
    - name: Report resolver success
      ansible.builtin.debug:
        msg: RESOLVER OK
      tags: [always]
    - name: Report where Ansible keeps its local temp files
      ansible.builtin.debug:
        msg: "LOCALTMP={{ lookup('ansible.builtin.config', 'DEFAULT_LOCAL_TMP') }} PROCTMP={{ lookup('ansible.builtin.env', 'TMPDIR') }} CPDIR={{ lookup('ansible.builtin.config', 'control_path_dir', plugin_type='connection', plugin_name='ssh') }}"
      tags: [localtmp]
    - name: Flag early
      ansible.builtin.debug:
        msg: FLAG-EARLY
      tags: [flags]
    - name: Flag mode
      ansible.builtin.debug:
        msg: "FLAG-CHECK={{ ansible_check_mode }} FLAG-DIFF={{ ansible_diff_mode }} FLAG-VERB={{ ansible_verbosity }}"
      tags: [flags]
    - name: Flag skipped by tag
      ansible.builtin.debug:
        msg: FLAG-SKIPME
      tags: [flags, skipme]
    - name: Flag late
      ansible.builtin.debug:
        msg: FLAG-LATE
      tags: [flags]
    - name: Use a module from a user-installed collection
      hermesfix.demo.hello:
      register: fx_collection
      tags: [collection]
    - name: Report the collection result
      ansible.builtin.debug:
        msg: "{{ fx_collection.msg }}"
      tags: [collection]
    - name: Leak canaries through a debug message
      ansible.builtin.debug:
        msg: "LEAK-MSG {{ secrets.fix_token }} {{ secrets.fix_special }} {{ secrets.fix_short }}"
      tags: [leak]
    - name: Leak canaries JSON-escaped (non-ASCII becomes \\u sequences)
      ansible.builtin.debug:
        msg: "LEAK-JSON {{ secrets.fix_unicode | to_json }} {{ secrets.fix_special | to_json }}"
      tags: [leak]
    - name: Leak canaries URL-encoded
      ansible.builtin.debug:
        msg: "LEAK-URL {{ secrets.fix_unicode | urlencode }} {{ secrets.fix_special | urlencode }}"
      tags: [leak]
    - name: Leak a value that contains another value
      ansible.builtin.debug:
        msg: "LEAK-WRAP {{ secrets.fix_container }}"
      tags: [leak]
    - name: Leak two values that overlap in the output
      ansible.builtin.debug:
        msg: "LEAK-OVERLAP {{ secrets.fix_token }}-overlap-zz"
      tags: [leak]
    - name: A value below the minimum length is not masked
      ansible.builtin.debug:
        msg: "LEAK-TINY {{ secrets.fix_tiny }} abcdef"
      tags: [leak]
    - name: Leak through a rendered template diff
      ansible.builtin.template:
        src: leak.j2
        dest: "{{ lookup('ansible.builtin.env', 'TMPDIR') }}/leak.conf"
        mode: "0600"
      tags: [leak]
    - name: Leak through verbose task arguments and results
      ansible.builtin.command:
        cmd: "echo LEAK-CMD {{ secrets.fix_token }} {{ secrets.fix_unicode }}"
      changed_when: false
      check_mode: false
      tags: [leak]
    - name: A task that fails
      ansible.builtin.fail:
        msg: deliberate failure
      tags: [failing]
    - name: Stream first
      ansible.builtin.debug:
        msg: STREAM-FIRST
      tags: [slow]
    - name: Wait
      ansible.builtin.pause:
        seconds: 8
      tags: [slow]
    - name: Stream last
      ansible.builtin.debug:
        msg: STREAM-LAST
      tags: [slow]
Y
  # the age identity and the SOPS configuration (recipients scoped to the store's path)
  age-keygen -o "$FIX_KEY" >/dev/null 2>&1
  chmod 600 "$FIX_KEY"
  FIX_PUB="$(age-keygen -y "$FIX_KEY")"
  cat > "$repo/.sops.yaml" <<S
creation_rules:
  - path_regex: ^secrets/secrets\.enc\.env\$
    key_groups:
      - age:
          - $FIX_PUB
S
  printf 'TARGET_HOST=%s\nFIX_TOKEN=%s\nFIX_DOMAIN=%s\nFIX_UNICODE=%s\nFIX_SHORT=%s\nFIX_SPECIAL=%s\nFIX_CONTAINER=%s\nFIX_TINY=%s\nFIX_OVERLAP=%s\nFIX_LONGER=%s\nFIX_QUOTES=%s\n' \
    "$CANARY_HOST" "$CANARY_TOKEN" "$CANARY_DOMAIN" "$CANARY_UNICODE" "$CANARY_SHORT" "$CANARY_SPECIAL" "$CANARY_CONTAINER" "$CANARY_TINY" "$CANARY_OVERLAP" "$CANARY_LONGER" "$CANARY_QUOTES" > "$dir/plain/store.env"
  ( cd "$repo" && sops encrypt --filename-override secrets/secrets.enc.env --input-type dotenv --output-type dotenv "$dir/plain/store.env" >"$repo/secrets/secrets.enc.env" )
  FIX_PLAIN="$dir/plain/store.env"
}

fx_deploy() {
  set +e
  OUT="$(cd / && env -i PATH="${FX_PATH:-$PATH}" HOME="$FIX_HOME" XDG_RUNTIME_DIR="${FX_RUN_OVERRIDE:-$FIX_RUN}" TMPDIR="$FIX_TMP" \
        HERMES_SECRETS_KEY_FILE="${FIX_KEY_OVERRIDE:-$FIX_KEY}" ${FX_EXTRA_ENV:-} \
        "$FIX_REPO/scripts/deploy" "$@" 2>&1)"
  RC=$?
  set -e
}

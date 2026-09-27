# Sourced by tests/check-secrets-helper.sh. Builds a throwaway repository tree with a COPY of the secrets helper,
# the real name-set code (scripts/hermes_secrets.py) and the structural guard, plus a small fixture manifest.
# No real key or secret is ever needed. Two separate "workstation" HOME directories (FIX_HOME1, FIX_HOME2) are
# used throughout so a test can never mistake "sops fell back to another identity that happens to also work" for
# "the key under test actually decrypted it" — a real trap: sops silently falls back to the OS-default identity
# file if SOPS_AGE_KEY_FILE points nowhere, so a naive test's negative case can pass for the wrong reason.

CANARY_VALUE='tok-9f8e7d6c5b4a3210'

make_secrets_fixture() {
  local dir="$1" repo="$1/repo"
  FIX_REPO="$repo"; FIX_HOME1="$dir/home1"; FIX_HOME2="$dir/home2"; FIX_BG_DIR="$dir/breakglass"
  mkdir -p "$repo/scripts" "$repo/group_vars/all" "$FIX_HOME1" "$FIX_HOME2" "$FIX_BG_DIR" "$dir/plain"
  local src="${FIX_SRC_ROOT:?}"
  for f in secrets hermes_secrets.py hermes_bootstrap.py check_secrets_store.py generate-env.py; do
    cp "$src/scripts/$f" "$repo/scripts/$f"
  done
  chmod +x "$repo/scripts/secrets"
  cat > "$repo/group_vars/all/secrets.yml" <<'M'
secrets_manifest:
  fix_token:    { env: FIX_TOKEN,    required: true }
  fix_domain:   { env: FIX_DOMAIN,   required: true }
  fix_opt:      { env: FIX_OPT,      default: "dflt" }
M
  # scripts/secrets locates the repo from its OWN path (scripts/..), independent of cwd — proven by running every
  # command from an unrelated cwd below.
}

# run_secrets HOME [EXTRA_ENV=VAL ...] -- ARG...   -> sets OUT, RC (cwd is deliberately NOT the repo)
run_secrets() {
  local home="$1"; shift
  local extra=()
  while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done
  shift
  set +e
  OUT="$(cd / && env -i PATH="$PATH" HOME="$home" "${extra[@]}" python3 "$FIX_REPO/scripts/secrets" "$@" 2>&1)"; RC=$?
  set -e
}

new_key() {  # new_key HOME -> prints the public key; the private key lands at HOME/.config/sops/age/keys.txt
  run_secrets "$1" -- init-key
  [[ $RC -eq 0 ]] || { echo "$OUT" >&2; echo "FAIL: init-key failed for $1" >&2; exit 1; }
  echo "$OUT"
}

# decrypt_as HOME [EXTRA_ENV=VAL ...] -- STORE_PATH   -> sets OUT, RC, using ONLY that HOME's default key location
# (never HERMES_SECRETS_KEY_FILE — this is what proves a given identity, and only that identity, can decrypt)
decrypt_as() {
  local home="$1"; shift
  local extra=()
  while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done
  shift
  set +e
  OUT="$(cd / && env -i PATH="$PATH" HOME="$home" "${extra[@]}" sops decrypt --input-type dotenv --output-type json "$1" 2>&1)"; RC=$?
  set -e
}

# fill_via_pty HOME VALUE_FOR_FIRST_PROMPT ...  -> sets OUT, RC; drives `scripts/secrets fill` under a REAL
# pseudo-terminal (pty.fork(), which gives the child a controlling terminal — the same thing getpass.getpass() and
# sys.stdin.isatty() need), so this exercises the actual hidden-input code path, not a monkeypatched stand-in. Only
# PATH and HOME are set (HOME alone determines the default key location — the same convention every other test here
# uses), matching a real interactive session; the typed values must NOT appear in $OUT (a real terminal without
# echo would not show them either).
fill_via_pty() {
  local home="$1"; shift
  set +e
  OUT="$(PYTHONPATH= FIX_SCRIPT="$FIX_REPO/scripts/secrets" FIX_HOME="$home" python3 - "$@" <<'PY'
import codecs, os, pty, sys, time

values = sys.argv[1:]
script, home, path = os.environ["FIX_SCRIPT"], os.environ["FIX_HOME"], os.environ["PATH"]
pid, fd = pty.fork()
if pid == 0:
    os.environ.clear()
    os.environ["PATH"] = path
    os.environ["HOME"] = home
    os.chdir("/")
    os.execvp("python3", ["python3", script, "fill"])
out = b""
decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
idx = 0
deadline = time.time() + 15
timed_out = False
while time.time() < deadline:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    text = decoder.decode(chunk)
    if text and idx < len(values) and text.rstrip("\n").endswith(": "):
        os.write(fd, (values[idx] + "\n").encode())
        idx += 1
else:
    timed_out = True   # the while's own condition ran out, not a `break` — the child never gave us EOF
# Never block forever on a child that misbehaves under a mutation: give it a moment to exit on its own, then kill it.
for _ in range(20):
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    time.sleep(0.1)
else:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)
    timed_out = True
rc = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)
sys.stdout.buffer.write(out)
if timed_out:
    sys.stdout.write("\n[fill_via_pty: TIMED OUT waiting for the child]\n")
    sys.exit(1)
sys.exit(rc)
PY
)"; RC=$?
  set -e
}

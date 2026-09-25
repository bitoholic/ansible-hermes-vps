#!/usr/bin/env bash
# Epic 22 ticket #01 guard: the deploy wrapper (scripts/deploy), treated as a BLACK BOX.
#
# It runs a copy of the wrapper inside a throwaway repository tree (the real `secrets` resolver role, a fixture
# manifest and playbook, a throwaway age key, a fixture store of canary values) and looks only at what the
# wrapper prints, what it exits with, what the child received, and what is left on disk. No real key or secret
# is ever needed or read.
#
# What this CANNOT verify: the real store and key (the operator's migration, ticket #09), a real deployment to
# the VPS, or the agent sandbox (ticket #08). Redaction of the output is ticket #02's test.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
FIX_SRC_ROOT="$ROOT_DIR"
# shellcheck source=tests/support/deploy-fixture.sh
source tests/support/deploy-fixture.sh
fail() { echo "FAIL: $*" >&2; [[ -n "${OUT:-}" ]] && { echo "--- output ---" >&2; echo "$OUT" >&2; }; exit 1; }

for tool in sops age age-keygen ansible-playbook ansible-config; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is not installed (required by the epic 22 tests; see docs onboarding)" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
make_fixture "$T"
echo "== deploy wrapper guard (epic 22 #01) =="

# --- happy path: decrypt to the environment, run the real resolver, exit 0 ------------------------------
fx_deploy --tags always
[[ $RC -eq 0 ]] || fail "the happy path exited $RC"
grep -q 'RESOLVER OK' <<<"$OUT" || fail "the resolver did not receive the fixture values (seam broken)"
grep -q 'ok=' <<<"$OUT" || fail "no play recap"
# (the target host is one of the store's values, so it is itself masked in the output)
grep -q 'ok: \[\[redacted\]\]' <<<"$OUT" && ! grep -q '127.0.0.2' <<<"$OUT" || fail "the play did not target the host read from the store (or the host was printed unmasked)"
echo "runs the fixture playbook; the real resolver received the store's values (target host read from the store)"

# --- no plaintext file anywhere, including Ansible's own temp and cache locations ------------------------
# Search the repository tree, HOME, the runtime dir, TMPDIR and /tmp-like locations for every canary value.
for canary in "$CANARY_TOKEN" "$CANARY_DOMAIN" "$CANARY_UNICODE" "$CANARY_SHORT" "$CANARY_SPECIAL" "$CANARY_QUOTES"; do
  hits="$(grep -rla -F -- "$canary" "$FIX_REPO" "$FIX_HOME" "$FIX_RUN" "$FIX_TMP" 2>/dev/null | grep -v '^$' || true)"
  # the fixture's own site.yml and show-env script legitimately contain the canaries as assertion literals; nothing else may.
  hits="$(grep -v -x -e "$FIX_REPO/site.yml" -e "$FIX_REPO/scripts/fx-show-env.sh" <<<"$hits" || true)"
  [[ -z "$hits" ]] || fail "a decrypted value was written to disk: $hits"
done
[[ -z "$(ls -A "$FIX_RUN")" ]] || fail "the wrapper left files in the runtime directory: $(ls -A "$FIX_RUN")"
echo "no decrypted value on disk after a run; the wrapper's private scratch directory is removed"

# --- exit status and streaming ---------------------------------------------------------------------------
fx_deploy --tags failing
[[ $RC -eq 2 ]] || fail "a failing playbook must return Ansible's status 2 (got $RC)"
fx_deploy --script exit-seven
[[ $RC -eq 7 ]] || fail "script mode must return the script's own status (got $RC)"
fx_deploy --script show-env a1 b2
[[ $RC -eq 0 ]] && grep -q 'SCRIPT SAW THE STORE' <<<"$OUT" && grep -q 'args: a1 b2' <<<"$OUT" || fail "a registered script did not get the decrypted environment and its arguments"
grep -q 'KEY SOURCE NOT EXPOSED' <<<"$OUT" || fail "the child was handed the key source or store location"
fx_deploy --tags localtmp
grep -qF "LOCALTMP=$FIX_RUN/hermes-deploy-" <<<"$OUT" || fail "Ansible's local temp directory is not the wrapper's private scratch directory"
grep -qE "CPDIR=$FIX_RUN/hermes-deploy-[^/ ]+/cp([ \"]|\$)" <<<"$OUT" || fail "ssh control sockets were not pinned into the wrapper's scratch directory"
grep -qF "PROCTMP=$FIX_RUN/hermes-deploy-" <<<"$OUT" || fail "TMPDIR was not pinned to the wrapper's private scratch directory"
# a runtime directory too long for ssh's control-socket path must not be used (it would break every deployment)
LONG="$T/$(printf 'x%.0s' $(seq 1 40))/run"; mkdir -p "$LONG"
# ...and one only a little over the cap (ssh's socket path must keep a margin for verify-live's longer name under TMPDIR)
pad=$(( 43 - ${#T} - 5 )); MID="$T/$(printf 'y%.0s' $(seq 1 $pad))/run"; mkdir -p "$MID"
FX_RUN_OVERRIDE="$MID" fx_deploy --tags localtmp
[[ $RC -eq 0 ]] && grep -q 'LOCALTMP=' <<<"$OUT" && ! grep -qF "$MID" <<<"$OUT" || fail "a runtime directory of ${#MID} characters (over the scratch-parent cap) was used"
FX_RUN_OVERRIDE="$LONG" fx_deploy --tags localtmp
[[ $RC -eq 0 ]] && grep -q 'LOCALTMP=' <<<"$OUT" && ! grep -qF "$LONG" <<<"$OUT" || fail "a runtime directory too long for ssh control sockets was used as the scratch parent"
echo "exit status equals the child's (playbook and script mode); scripts receive the store's values; the key source is not passed on; Ansible's local temp is private"

: > "$T/live.out"
( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --tags slow >"$T/live.out" 2>&1 ) &
pid=$!
seen=0
for _ in $(seq 1 60); do   # up to 6 s: the play pauses for 8 s after the first message
  sleep 0.1
  if grep -q 'STREAM-FIRST' "$T/live.out"; then seen=1; break; fi
done
if (( seen )) && kill -0 "$pid" 2>/dev/null; then live=1; else live=0; fi
wait "$pid" || true
(( live )) || { cat "$T/live.out" >&2; fail "output did not stream live (the first message only arrived at the end)"; }
grep -q 'STREAM-LAST' "$T/live.out" || fail "the streamed run did not finish"
echo "output streams live"

# --- output redaction (ticket #02): the canary test -------------------------------------------------------
# An independent ORACLE computes every form a value may take in output (plain, JSON with and without \u escapes, repr,
# URL-encoded); none may appear anywhere in the combined output, while markers prove the leaking tasks really ran.
oracle() {  # oracle <value...>: print every form, one per line, that must never appear (written independently of the redactor)
  python3 - "$@" <<'E'
import json, re, sys, urllib.parse
def json_levels(v, depth):
    out, cur = set(), {v}
    for _ in range(depth):
        cur = {json.dumps(x, ensure_ascii=a)[1:-1] for x in cur for a in (True, False)}
        out |= cur
    return out
for v in sys.argv[1:]:
    forms = {v, repr(v)[1:-1]}
    for j in json_levels(v, 3):
        forms |= {j, j.replace("/", "\\/"), re.sub(r"\\u([0-9a-f]{4})", lambda m: "\\u" + m.group(1).upper(), j)}
    for q in (urllib.parse.quote(v, safe=""), urllib.parse.quote(v), urllib.parse.quote_plus(v)):
        forms |= {q, re.sub(r"%[0-9A-F]{2}", lambda m: m.group(0).lower(), q)}
    for f in forms:
        if len(f) >= 4:
            print(f)
E
}
assert_no_canary() {  # assert_no_canary <label>  (reads $OUT)
  local form
  while IFS= read -r form; do
    [[ -z "$form" ]] && continue
    [[ "$OUT" != *"$form"* ]] || fail "$1: a decrypted value leaked into the output (form: ${form:0:6}…)"
  done < <(oracle "$CANARY_TOKEN" "$CANARY_DOMAIN" "$CANARY_UNICODE" "$CANARY_SHORT" "$CANARY_SPECIAL" "$CANARY_CONTAINER" "$CANARY_HOST" "$CANARY_OVERLAP" "$CANARY_LONGER" "$CANARY_QUOTES")
}
fx_deploy --tags leak --check --diff -vvvvvv
[[ $RC -eq 0 ]] || fail "the leak play did not run cleanly (rc=$RC)"
for marker in LEAK-MSG LEAK-JSON LEAK-URL LEAK-WRAP LEAK-TINY LEAK-CMD 'token=' ; do
  grep -q "$marker" <<<"$OUT" || fail "the leaking task for '$marker' did not produce output (vacuous test)"
done
assert_no_canary "debug message, JSON, URL, template diff and verbose arguments at -vvvvvv"
grep -q 'LEAK-MSG \[redacted\] \[redacted\] \[redacted\]' <<<"$OUT" || fail "values in a debug message were not masked (or the masks are not where expected)"
grep -E 'LEAK-JSON' <<<"$OUT" | grep -q '\[redacted\].*\[redacted\]' || fail "the JSON-escaped (nested) values on the LEAK-JSON line were not masked"
grep -E 'LEAK-URL' <<<"$OUT" | grep -q '\[redacted\].*\[redacted\]' || fail "the URL-encoded values on the LEAK-URL line were not masked"
grep -qE 'LEAK-WRAP \[redacted\]($|[^A-Za-z0-9-])' <<<"$OUT" || fail "a value containing another value was not masked completely"
! grep -q 'wrap-' <<<"$OUT" || fail "a readable fragment of a value that contains another value remains"
grep -qE 'LEAK-OVERLAP \[redacted\]($|[^A-Za-z0-9-])' <<<"$OUT" && ! grep -q -- '-overlap' <<<"$OUT" || fail "two values that overlap in the output left a readable fragment"
grep -q 'LEAK-TINY abc abcdef' <<<"$OUT" || fail "a value below the minimum length must NOT be masked (the documented constant)"
grep -qE "^\+token=|token=\[redacted\]" <<<"$OUT" || fail "the rendered diff did not show the masked template"
# the same at lower verbosity and without diff, and in script mode with values split at every position across reads
fx_deploy --tags leak;      assert_no_canary "default verbosity"
fx_deploy --tags leak -vvv; assert_no_canary "-vvv"
fx_deploy --script split
[[ $RC -eq 0 ]] || fail "the split-value script did not run (rc=$RC)"
assert_no_canary "values split across output chunks (stdout and stderr)"
[[ "$(grep -c 'SPLIT\[\[redacted\]\]' <<<"$OUT")" -ge 20 ]] || fail "the split-value script's output was not masked as expected (vacuous test)"
fx_deploy --script tail
[[ "$OUT" == "END-${CANARY_TOKEN:0:3}" ]] || fail "the held-back tail of a stream must be flushed at the end (got: ${OUT:0:20})"
fx_deploy --script tail-full
[[ "$OUT" == "[redacted]" ]] || fail "a value held back at the end of the stream must be masked when flushed (got: ${OUT:0:30})"
# --- the redactor itself: properties the black-box run cannot reach ---------------------------------------------
python3 - "$ROOT_DIR" <<'E' || fail "the redactor's property checks failed"
import importlib.machinery, importlib.util, json, os, random, re, sys, time, urllib.parse
root = sys.argv[1]
def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader); mod = importlib.util.module_from_spec(spec); sys.modules[name] = mod; loader.exec_module(mod); return mod
R = load("hermes_redact_t", os.path.join(root, "scripts", "hermes_redact.py"))
MASK = R.MASK
def run(values, chunks):
    x = R.StreamRedactor(values); out = b"".join(x.feed(c) for c in chunks) + x.finish(); return out
def collapse(b):  # adjacent masks are one mask (a match split across chunks may print two)
    return re.sub(rb"(\[redacted\])+", b"[redacted]", b)
# 1. random values, texts and splits: the split output equals the one-shot output, and no value survives
rnd = random.Random(20260925)
alphabet = ["a", "b", "%", "2", "0", " ", "/", "\\", "\"", "'", "\n", "é", "ż", "-"]
for case in range(400):
    values = ["".join(rnd.choice(alphabet) for _ in range(rnd.randint(4, 9))) for _ in range(rnd.randint(1, 4))]
    if rnd.random() < .5:
        values.append(values[0][:rnd.randint(4, len(values[0]))] + "".join(rnd.choice(alphabet) for _ in range(3)))   # a prefix/overlap
    text = "".join(rnd.choice(alphabet + values + [json.dumps(v)[1:-1] for v in values] + [urllib.parse.quote(v) for v in values]) for _ in range(rnd.randint(1, 30))).encode()
    whole = collapse(run(values, [text]))
    cuts = sorted(rnd.sample(range(1, max(2, len(text))), min(3, max(0, len(text) - 1)))) if len(text) > 1 else []
    parts = [text[a:b] for a, b in zip([0] + cuts, cuts + [len(text)])]
    assert collapse(run(values, parts)) == whole, ("split differs", values, text, parts)
    assert collapse(run(values, [bytes([b]) for b in text])) == whole, ("byte-wise differs", values, text)
    for v in values:
        if len(v) >= R.MIN_REDACT_LEN:
            assert v.encode() not in whole, ("value survived", v, text, whole)
# 1b. RUN-HEAVY texts (long merged runs of matches: repeated values, periodic and bordered values, a value that is a prefix
# of another) against a plain WHOLE-BUFFER reference: split output must equal it — the bounded-growth path must never
# print a fragment of a value that is part of a run
def reference(values, text):
    needles = set()
    for v in values:
        if len(v) >= R.MIN_REDACT_LEN: needles |= R.variants(v)
    spans = []
    for n in needles:
        i = text.find(n)
        while i != -1: spans.append((i, i + len(n))); i = text.find(n, i + 1)
    spans.sort(); out, pos = [], 0
    for a, b in spans:
        if b <= pos: continue
        out.append(text[pos:max(pos, a)]); out.append(MASK); pos = b
    out.append(text[pos:]); return b"".join(out)
rr = random.Random(11)
families = [["aaaa"], ["aaaa", "aaaabXYZ"], ["abab", "ababab"], ["aaaaaa"], ["bbbb/a", "bbbb/abb", "bbbbbbb/a"], ["abcabcabc"], ["q" * 12, "qqqq"]]
for case in range(300):
    values = rr.choice(families)
    unit = rr.choice(values + [json.dumps(values[0])[1:-1], urllib.parse.quote(values[0]), "x", "\n", " b"])
    text = (unit * rr.randint(3, 120) + rr.choice(["", "\n", " tail", values[-1][:2]])).encode()
    text = text + (rr.choice(values) + "Z\n").encode() if rr.random() < .4 else text
    want = collapse(reference(values, text))
    for step in (1, 3, len(min(values, key=len)), max(len(v) for v in values), 97):
        assert collapse(run(values, [text[i:i + step] for i in range(0, len(text), step)])) == want, ("run-heavy split differs", values, step, text[:60], len(text))
    cuts = sorted(rr.sample(range(1, len(text)), min(4, len(text) - 1)))
    assert collapse(run(values, [text[a:b] for a, b in zip([0] + cuts, cuts + [len(text)])])) == want, ("run-heavy random split differs", values, text[:60])
# 2. every documented form of a value is masked (each computed here, independently of the redactor)
v = "a b/ü%\u017c \"q\" \\x"
forms = {"plain": v, "json ascii": json.dumps(v)[1:-1], "json utf8": json.dumps(v, ensure_ascii=False)[1:-1],
         "json slash": json.dumps(v)[1:-1].replace("/", "\\/"),
         "json upper hex": re.sub(r"\\u([0-9a-f]{4})", lambda m: "\\u" + m.group(1).upper(), json.dumps(v)[1:-1]),
         "quote": urllib.parse.quote(v, safe=""), "quote_plus": urllib.parse.quote_plus(v),
         "quote lower hex": re.sub(r"%[0-9A-F]{2}", lambda m: m.group(0).lower(), urllib.parse.quote(v, safe="")),
         "json in json": json.dumps(json.dumps(v)[1:-1])[1:-1], "json in json in json": json.dumps(json.dumps(json.dumps(v)[1:-1])[1:-1])[1:-1],
         "repr": repr(v)[1:-1],
         "json utf8 in json utf8": json.dumps(json.dumps(v, ensure_ascii=False)[1:-1], ensure_ascii=False)[1:-1],
         "json slash + upper hex": re.sub(r"\\u([0-9a-f]{4})", lambda m: "\\u" + m.group(1).upper(), json.dumps(v)[1:-1]).replace("/", "\\/"),
         "json ascii in json utf8": json.dumps(json.dumps(v)[1:-1], ensure_ascii=False)[1:-1],
         "json utf8 in json ascii": json.dumps(json.dumps(v, ensure_ascii=False)[1:-1])[1:-1],
         "json utf8 x3": json.dumps(json.dumps(json.dumps(v, ensure_ascii=False)[1:-1], ensure_ascii=False)[1:-1], ensure_ascii=False)[1:-1]}
for label, f in forms.items():
    out = run([v], [("x " + f + " y").encode()])
    assert f.encode() not in out and MASK in out, ("form not masked", label, f, out)
# 2b. a self-overlapping (periodic) value leaves no fragment where its occurrences overlap
out = run(["abababab"], [b"x abababababab y"])
assert b"ab" not in out.replace(b"[redacted]", b"").replace(b"y", b"").replace(b"x", b""), ("overlapping occurrences left a fragment", out)
# 2c. ordinary output is not held back: a complete line is emitted at once (only a possible value PREFIX waits)
x = R.StreamRedactor(["tok-abcdef", "qqqq"])
assert x.feed(b"a complete line\n") == b"a complete line\n", "a line was held back"
assert x.feed(b"ends like a value: to") == b"ends like a value: ", "the held tail is more than the possible value prefix"
assert x.feed(b"k-abcdef!") == b"[redacted]!", "a value split across chunks was not masked"
# 3. a long run of value-shaped output neither stalls nor grows the buffer: it is emitted progressively and quickly
for vals, size in ((["aaaa"], 1_500_000), (["ab" * 6], 600_000)):
    x = R.StreamRedactor(vals); t0 = time.time(); emitted = 0; peak = 0
    data = (b"a" if vals[0][0] == "a" and len(set(vals[0])) == 1 else b"ab") * (size if len(set(vals[0])) == 1 else size // 2)
    for i in range(0, len(data), 4096):
        emitted += len(x.feed(data[i:i + 4096])); peak = max(peak, len(x._buf))
    assert emitted > 0, "output was withheld until the end of the run"
    stream = b"".join(  # the same run again, collecting every emitted byte: nothing but masks may come out
        [y for y in (lambda z: [z.feed(data[i:i + 4096]) for i in range(0, len(data), 4096)] + [z.finish()])(R.StreamRedactor(vals))])
    assert stream.replace(MASK, b"") == b"", ("a fragment of a run of the value was emitted", stream.replace(MASK, b"")[:40])
    assert peak <= 3 * max(len(n) for n in x._needles), ("the carry grew beyond its bound", peak)
    assert time.time() - t0 < 10, ("too slow", time.time() - t0)
    tail = x.finish(); assert vals[0].encode() not in tail
# 3b. the carry stays within ~3*maxlen even for a run of only a dozen value-lengths fed byte by byte
x = R.StreamRedactor(["aaaa"]); peak = 0
for b in b"a" * (12 * x._maxlen):
    x.feed(bytes([b])); peak = max(peak, len(x._buf))
assert peak <= 3 * x._maxlen, ("the carry grew beyond its bound on a medium run", peak, x._maxlen)
# 4. a lone surrogate in a value does not crash construction
R.StreamRedactor(["ab\udcffcd"]); R.StreamRedactor(["ab\ud800cd"])
# 5. a redactor that raises must not leak or block: the pump withholds the rest of the stream and keeps draining
D = load("deploy_t", os.path.join(root, "scripts", "deploy"))
class Boom:
    def feed(self, c): raise RuntimeError("boom")
    def finish(self): raise RuntimeError("boom")
class BoomAtEnd:                      # feed works, finish() raises: the carry must not be printed raw
    def __init__(self): self.r = R.StreamRedactor(["secret-looking"])
    def feed(self, c): return self.r.feed(c)
    def finish(self): raise RuntimeError("boom")
import threading
class Sink:
    def __init__(self): self.got = []
    def write(self, b): self.got.append(b)
    def flush(self): pass
def drive(redactor, payload):
    r, w = os.pipe(); sink = Sink(); st = {"writing": False, "last": time.time()}; fed = threading.Event()
    th = threading.Thread(target=D.pump, args=(r, sink, redactor, st), daemon=True); th.start()
    def feeder():                       # from a helper thread: a pump that stops draining fails the test instead of hanging it
        try:
            for chunk in payload: os.write(w, chunk)
            fed.set()
        finally:
            os.close(w)
    threading.Thread(target=feeder, daemon=True).start()
    th.join(10)
    return sink, th, fed
sink, th, fed = drive(Boom(), [b"secret-looking data " * 1000, b"more" * 100000])
assert fed.is_set(), "the pump stopped draining after the redactor failed (the child would block on a full pipe)"
assert not th.is_alive(), "the pump blocked behind a failing redactor"
assert b"secret-looking" not in b"".join(sink.got), "a failing redactor let raw output through"
sink, th, fed = drive(BoomAtEnd(), [b"prefix secret-look"])       # ends holding a possible value prefix
assert fed.is_set() and not th.is_alive(), "the pump did not finish when finish() raised"
assert b"secret-look" not in b"".join(sink.got), "the held carry was printed raw when finish() failed"
E
# a long run of value-shaped output (the repeated value 'qqqq') through the wrapper: masked, complete, prompt, and delivered while it runs
start=$SECONDS; fx_deploy --script repeat
(( SECONDS - start < 20 )) || fail "a 3 MB run of value-shaped output took $((SECONDS - start)) s (quadratic redaction)"
[[ $RC -eq 0 ]] && grep -q '\[redacted\]' <<<"$OUT" && ! grep -q 'qqqq' <<<"$OUT" || fail "a run of a repeated value was not masked (rc=$RC)"
: > "$T/rep.out"
( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --script repeat-slow >"$T/rep.out" 2>&1 ) &
rpid=$!; seen=0
for _ in $(seq 1 25); do sleep 0.2; grep -q '\[redacted\]' "$T/rep.out" && { seen=1; break; }; done   # the script pauses 4 s after its first 100 KB
if (( seen )) && kill -0 "$rpid" 2>/dev/null; then :; else wait "$rpid" || true; fail "the first 100 KB of a repeated-value run was withheld until the end (stall)"; fi
wait "$rpid" || true
# the run ENDS at a read boundary here (a pause, then a different byte): no readable part of the value may remain, and no fragment
grep -q 'recap-ok' "$T/rep.out" && ! grep -q 'qqq' "$T/rep.out" || fail "a fragment of a repeated-value run that ended at a read boundary was printed"
echo "redaction: canaries in debug messages, JSON/URL forms, template diffs and verbose arguments (-vvvvvv), split across chunks, nested — none in the output; values below the minimum are documented as unmasked"

# --- refused invocation shapes (each: exit 64, and the child never ran) ---------------------------------
refused() {  # refused <label> args...
  local label="$1"; shift
  fx_deploy "$@"
  [[ $RC -eq 64 ]] || fail "'$label' must be refused with status 64 (got $RC)"
  grep -q 'refused' <<<"$OUT" || fail "'$label': the refusal was not explained"
  ! grep -qE 'PLAY \[|PLAY RECAP|RESOLVER OK' <<<"$OUT" || fail "'$label': the child ran although the invocation was refused"
}
refused "extra vars"            -e x=1
refused "extra vars long"       --extra-vars x=1
refused "extra vars inline"     --extra-vars=x=1
refused "extra vars file"       -e @/etc/passwd
refused "extra vars glued"      -ex=1
refused "ad-hoc module"         -m ping
refused "module args"           -a 'id'
refused "inventory"             -i other.ini
refused "connection"            --connection ssh
refused "another playbook"      other.yml
refused "parent path"           ../site.yml
refused "absolute path"         /etc/hostname
refused "unknown flag"          --become-user root
refused "tags with space"       --tags 'a b'
refused "tags with shell"       --tags 'a;id'
refused "limit from file"       --limit @/etc/hosts
refused "limit from a relative file" --limit=@hosts
refused "start-at-task flag"    --start-at-task --check
refused "verbosity too high"    -vvvvvvv
refused "missing value"         --tags
refused "tags starting with -"  --tags=-x
refused "limit starting with -" --limit=-x
fx_deploy --script nope;               [[ $RC -eq 64 ]] || fail "an unregistered script must be refused (got $RC)"
fx_deploy --script ../outside.sh;      [[ $RC -eq 64 ]] || fail "a script path must be refused (got $RC)"
fx_deploy --script escape;             [[ $RC -eq 64 ]] && grep -q 'outside the repository' <<<"$OUT" || fail "a registered entry resolving outside the repository must be refused"
fx_deploy --script missing-file;       [[ $RC -eq 64 ]] && grep -q 'not present' <<<"$OUT" || fail "a registered script that is absent must be refused clearly"
fx_deploy --script show-env 'a;id';    [[ $RC -eq 64 ]] || fail "a script argument with shell metacharacters must be refused"
fx_deploy --tags always -C -D -vv -l 127.0.0.2 --skip-tags failing --start-at-task 'Report resolver success'
[[ $RC -eq 0 ]] || fail "the vetted flags (check, diff, tags, skip-tags, limit, verbosity, start-at-task) must pass through (got $RC)"
# ...and each one must actually TAKE EFFECT (a silently dropped --check would turn a dry run into a real deploy)
fx_deploy --tags flags
grep -q 'FLAG-CHECK=False FLAG-DIFF=False FLAG-VERB=0' <<<"$OUT" || fail "baseline flags are not as expected"
fx_deploy --tags flags -C;    grep -q 'FLAG-CHECK=True' <<<"$OUT" || fail "--check did not take effect"
fx_deploy --tags flags --check; grep -q 'FLAG-CHECK=True' <<<"$OUT" || fail "--check (long form) did not take effect"
fx_deploy --tags flags -D;    grep -q 'FLAG-DIFF=True' <<<"$OUT" || fail "--diff did not take effect"
fx_deploy --tags flags -vvv;  grep -q 'FLAG-VERB=3' <<<"$OUT" || fail "-vvv did not take effect"
fx_deploy --tags flags --skip-tags skipme; ! grep -q 'FLAG-SKIPME' <<<"$OUT" && grep -q 'FLAG-LATE' <<<"$OUT" || fail "--skip-tags did not take effect"
fx_deploy -t flags;           grep -q 'FLAG-SKIPME' <<<"$OUT" && grep -q 'FLAG-EARLY' <<<"$OUT" || fail "-t did not select the tagged tasks"
fx_deploy --tags flags --start-at-task 'Flag late'; grep -q 'FLAG-LATE' <<<"$OUT" && ! grep -q 'FLAG-EARLY' <<<"$OUT" || fail "--start-at-task did not take effect"
fx_deploy --tags flags -l 127.0.0.9; ! grep -q 'FLAG-EARLY' <<<"$OUT" || fail "--limit did not take effect (a task ran on a host outside the limit)"
refused "task name with control chars" --start-at-task $'a\nb'
refused "trailing newline in tags"      --tags $'flags\n'
# a file added to scripts/ must not shadow the standard library inside the wrapper process (which holds the decrypted values)
for mod in tempfile json subprocess shutil re; do
  printf 'import os\nopen(os.environ.get("HERMES_SHADOW_MARK", "%s/shadow-leak"), "a").write(repr(dict(os.environ)))\nraise SystemExit(99)\n' "$T" > "$FIX_REPO/scripts/$mod.py"
done
fx_deploy --script show-env
[[ $RC -eq 0 ]] && grep -q 'SCRIPT SAW THE STORE' <<<"$OUT" && [[ ! -e "$T/shadow-leak" ]] || fail "a file in scripts/ shadowed a standard-library module in the wrapper process (rc=$RC)"
rm -f "$FIX_REPO/scripts"/{tempfile,json,subprocess,shutil,re}.py
# scripts/ must not be an import source AT ALL: modules that do not exist elsewhere (msvcrt, which subprocess tries to
# import and is absent on Linux), an extension module and a package standing in for a sibling would all run inside the
# process that holds the decrypted values
printf 'import sys\ndef _h(event, args):\n    if event == "subprocess.Popen": open("%s/msvcrt-leak", "a").write(repr(args))\nsys.addaudithook(_h)\nraise ModuleNotFoundError("msvcrt")\n' "$T" > "$FIX_REPO/scripts/msvcrt.py"
so="$(python3 -c 'import importlib.machinery as m; print(m.EXTENSION_SUFFIXES[0])')"
printf 'not a real extension module' > "$FIX_REPO/scripts/hermes_redact$so"; cp "$FIX_REPO/scripts/hermes_redact$so" "$FIX_REPO/scripts/hermes_secrets$so"
mkdir -p "$FIX_REPO/scripts/hermes_redact"; printf 'open("%s/pkg-leak", "a").write("ran")\n' "$T" > "$FIX_REPO/scripts/hermes_redact/__init__.py"
fx_deploy --script show-env
[[ $RC -eq 0 && ! -e "$T/msvcrt-leak" && ! -e "$T/pkg-leak" ]] && grep -q 'SCRIPT SAW THE STORE' <<<"$OUT" || fail "a file added to scripts/ (msvcrt.py, an extension module, a package) ran inside the wrapper (rc=$RC)"
fx_deploy --tags always
grep -q 'ok: \[\[redacted\]\]' <<<"$OUT" || fail "with planted modules in scripts/ the real redactor was not the one used"
rm -rf "$FIX_REPO/scripts/msvcrt.py" "$FIX_REPO/scripts/hermes_redact$so" "$FIX_REPO/scripts/hermes_secrets$so" "$FIX_REPO/scripts/hermes_redact"
[[ -z "$(ls "$FIX_REPO/scripts" | grep -E '\.pyc$|__pycache__' || true)" ]] || fail "the wrapper wrote bytecode into scripts/"
# a compiled-bytecode file planted in scripts/__pycache__ (gitignored, so `git diff` stays clean) must not be loaded in place of the source
mkdir -p "$FIX_REPO/scripts/__pycache__"
printf 'import os\nclass StreamRedactor:\n    def __init__(self, values):\n        open("%s/pyc-leak", "a").write(repr(values))\n    def feed(self, c): return c\n    def finish(self): return b""\n' "$T" > "$T/evil_redact.py"
python3 - "$T/evil_redact.py" "$FIX_REPO/scripts/hermes_redact.py" <<'E'
import importlib.util, py_compile, sys
target = importlib.util.cache_from_source(sys.argv[2])
py_compile.compile(sys.argv[1], cfile=target, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)
E
fx_deploy --script show-env
[[ $RC -eq 0 && ! -e "$T/pyc-leak" ]] && grep -q 'SCRIPT SAW THE STORE' <<<"$OUT" || fail "planted bytecode in scripts/__pycache__ was loaded (rc=$RC)"
rm -rf "$FIX_REPO/scripts/__pycache__"
fx_deploy --script link;     [[ $RC -eq 64 ]] && grep -q 'outside the repository' <<<"$OUT" || fail "a registered symlink pointing outside the repository must be refused (rc=$RC)"
fx_deploy --script not-exec; [[ $RC -eq 64 ]] && grep -q 'not executable' <<<"$OUT" || fail "a non-executable registered script must be refused clearly (rc=$RC)"
fx_deploy --script kill-self; [[ $RC -eq 137 ]] || fail "a child killed by signal 9 must return 128+9 (got $RC)"
FX_EXTRA_ENV="ANSIBLE_FORCE_COLOR=1" fx_deploy --script show-env
grep -q 'ANSIBLE SETTINGS CLEARED' <<<"$OUT" || fail "an inherited ANSIBLE_* setting reached a script"
grep -q 'SCRIPT-STDERR-LINE' <<<"$OUT" || fail "the child's stderr was not passed through"
# the key source and store location are never handed to the child, whichever way they were supplied
printf '#!/usr/bin/env bash\ncat "%s"\n' "$FIX_KEY" > "$T/keycmd.sh"; chmod +x "$T/keycmd.sh"
FX_EXTRA_ENV="SOPS_AGE_KEY_CMD=$T/keycmd.sh" FIX_KEY_OVERRIDE="$T/keys/none.txt" fx_deploy --script show-env
[[ $RC -eq 0 ]] && grep -q 'SCRIPT SAW THE STORE' <<<"$OUT" && grep -q 'KEY SOURCE NOT EXPOSED' <<<"$OUT" || fail "SOPS_AGE_KEY_CMD (the Tier 2 hook) must work and not be passed on (rc=$RC)"
grep -q 'the age key comes from SOPS_AGE_KEY_CMD (keycmd.sh)' <<<"$OUT" || fail "using SOPS_AGE_KEY_CMD must be announced on stderr"
FX_EXTRA_ENV="SOPS_AGE_KEY_FILE=$FIX_KEY" fx_deploy --script show-env
[[ $RC -eq 0 ]] && grep -q 'KEY SOURCE NOT EXPOSED' <<<"$OUT" || fail "an inherited SOPS_AGE_KEY_FILE must not be passed on (rc=$RC)"
FX_EXTRA_ENV="_ANSIBLE_TEST_SETTING=1" fx_deploy --script show-env
grep -q 'ANSIBLE SETTINGS CLEARED' <<<"$OUT" || fail "an inherited _ANSIBLE_* setting reached a script"
FX_EXTRA_ENV="SOPS_AGE_KEY=$(grep AGE-SECRET-KEY "$FIX_KEY")" fx_deploy --script show-env
[[ $RC -eq 0 ]] && grep -q 'KEY SOURCE NOT EXPOSED' <<<"$OUT" || fail "SOPS_AGE_KEY must not be passed on (rc=$RC)"
fx_deploy --tags collection
[[ $RC -eq 0 ]] && grep -q 'COLLECTION-FOUND' <<<"$OUT" || fail "a collection installed under ~/.ansible/collections must stay discoverable under the pinned ANSIBLE_HOME (rc=$RC)"
fx_deploy --script sibling
[[ $RC -eq 64 ]] && grep -q 'outside the repository' <<<"$OUT" && ! grep -q 'sibling-ran' <<<"$OUT" || fail "a registry entry resolving to a sibling directory that merely shares the repository's name prefix must be refused (rc=$RC)"
# stdout and stderr stay separate
( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --script outerr >"$T/o.out" 2>"$T/o.err" ) || true
grep -q 'OUT-LINE' "$T/o.out" && ! grep -q 'ERR-LINE' "$T/o.out" && grep -q 'ERR-LINE' "$T/o.err" && ! grep -q 'OUT-LINE' "$T/o.err" || fail "stdout and stderr were not kept separate"
# stdout closed by the caller (>&-): no traceback, and the child still runs to completion
( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --script show-env >&- 2>"$T/closed.err" ); crc=$?
[[ $crc -eq 0 ]] && ! grep -q Traceback "$T/closed.err" || { cat "$T/closed.err" >&2; fail "a closed stdout must not crash the wrapper (rc=$crc)"; }
# a consumer that closes the pipe early (| head) must not hang the wrapper or its child
start=$SECONDS
( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    timeout 30 "$FIX_REPO/scripts/deploy" --script big-output 2>/dev/null | head -c 10 >/dev/null ) || true
(( SECONDS - start < 20 )) || fail "the wrapper hung when its consumer closed the pipe"
# a registered script runs with cwd = the repository root: an untracked re.py / yaml.py / json.py there must NOT be
# imported by the script's `python3 -c` (PYTHONSAFEPATH), and its temp files go to the private scratch directory
for m in re yaml json; do printf 'import os\nopen("%s/pypath-leak", "a").write(os.environ.get("FIX_TOKEN", ""))\n' "$T" > "$FIX_REPO/$m.py"; done
fx_deploy --script pyimport
[[ $RC -eq 0 && ! -e "$T/pypath-leak" ]] && grep -q 'IMPORT-OK' <<<"$OUT" || fail "an untracked re.py/yaml.py/json.py in the repository root ran inside a registered script (rc=$RC)"
grep -q 'TMPDIR-PRIVATE' <<<"$OUT" || fail "a registered script's TMPDIR is not the wrapper's private scratch directory"
rm -f "$FIX_REPO/re.py" "$FIX_REPO/yaml.py" "$FIX_REPO/json.py"
# a consumer that closes the pipe (| head) must not turn a successful child into exit status 120
( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --script big-output 2>"$T/head.err" | head -c 10 >/dev/null; exit "${PIPESTATUS[0]}" ) && hrc=0 || hrc=$?
[[ $hrc -eq 0 ]] && ! grep -q 'Exception ignored' "$T/head.err" || fail "a closed consumer changed the wrapper's exit status or printed an exception (rc=$hrc)"
# a stderr consumer that goes away while stdout is still live must not disturb stdout or the exit status
errout=$( ( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --script errclose 2> >(head -c 0) ) ) && erc=0 || erc=$?
[[ $erc -eq 0 && "$errout" == *OUT-LATE* ]] || fail "a closed stderr consumer disturbed stdout or the exit status (rc=$erc, stdout='$errout')"
# ^C sent to the wrapper alone: it keeps waiting for the child and reports its status (no traceback, play completes)
# (a background job in a non-interactive shell starts with SIGINT IGNORED, which Python would then keep: reset it first,
# or the signal below would be a no-op and this test vacuous)
( cd / && exec env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$FIX_REPO/scripts/deploy" --tags slow >"$T/int.out" 2>&1 ) &
ipid=$!
for _ in $(seq 1 60); do sleep 0.2; grep -q 'STREAM-FIRST' "$T/int.out" 2>/dev/null && break; done
kill -INT "$ipid"; wait "$ipid" && irc=0 || irc=$?
[[ $irc -eq 0 ]] && grep -q 'STREAM-LAST' "$T/int.out" && ! grep -q Traceback "$T/int.out" || { cat "$T/int.out" >&2; fail "SIGINT to the wrapper alone must not abort it (rc=$irc)"; }
# the TAIL of the output must survive a slow consumer: a child that writes 125 KB and exits, read by a consumer that
# starts reading late, must deliver every byte (the wrapper waits for a thread that is blocked WRITING)
got=$( ( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --script medium 2>/dev/null | ( sleep 8; wc -c ) ) )
[[ "$got" -eq 125001 ]] || fail "output was lost behind a slow consumer ($got of 125001 bytes delivered)"
for i in $(seq 1 10); do
  got=$( ( cd / && env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
      "$FIX_REPO/scripts/deploy" --script medium 2>/dev/null | wc -c ) )
  [[ "$got" -eq 125001 ]] || fail "output tail lost with a fast consumer, run $i ($got of 125001 bytes)"
done
# ^C to the wrapper alone WHILE it is delivering output to a slow consumer (the drain wait) must not lose output or abort
mkfifo "$T/fifo"; ( exec < "$T/fifo"; sleep 6; wc -c > "$T/fifo.count" ) &   # opens the fifo NOW (so the wrapper starts), reads late
( cd / && exec env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$FIX_REPO/scripts/deploy" --script medium >"$T/fifo" 2>"$T/fifo.err" ) &
fpid=$!
sleep 2; kill -INT "$fpid"; wait "$fpid" && frc=0 || frc=$?
for _ in $(seq 1 60); do [[ -s "$T/fifo.count" ]] && break; sleep 0.5; done
[[ $frc -eq 0 && "$(cat "$T/fifo.count" 2>/dev/null)" -eq 125001 ]] && ! grep -q Traceback "$T/fifo.err" || fail "^C during the drain wait lost output or aborted the wrapper (rc=$frc, bytes=$(cat "$T/fifo.count" 2>/dev/null))"
# a chatty grandchild holding the pipes must not outlive a SIGTERM (the wrapper is in its drain wait then)
( cd / && exec env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --script chatty >"$T/chatty.out" 2>&1 ) &
cpid=$!
for _ in $(seq 1 50); do sleep 0.2; grep -q 'parent-done' "$T/chatty.out" 2>/dev/null && break; done
sleep 1; kill -TERM "$cpid"; cstart=$SECONDS; wait "$cpid" || true
(( SECONDS - cstart < 12 )) || fail "SIGTERM did not cut short the wait on a chatty grandchild ($((SECONDS - cstart)) s)"
# a grandchild that keeps the pipes open after the child exits must not hold the wrapper (bounded wait)
start=$SECONDS; fx_deploy --script grandchild
[[ $RC -eq 0 ]] && grep -q 'parent-done' <<<"$OUT" || fail "the grandchild script should have returned 0 (rc=$RC)"
(( SECONDS - start < 7 )) || fail "a grandchild holding the pipes kept the wrapper waiting ($((SECONDS - start)) s)"
# SIGTERM to the wrapper reaches the child, and the scratch directory is still removed
( cd / && exec env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --tags slow >"$T/term.out" 2>&1 ) &    # exec: $! is the wrapper itself
tpid=$!
for _ in $(seq 1 60); do sleep 0.2; grep -q 'STREAM-FIRST' "$T/term.out" 2>/dev/null && break; done
[[ -n "$(ls -A "$FIX_RUN")" ]] || fail "the scratch directory did not exist during the run (test setup)"
kill -TERM "$tpid"; wait "$tpid" || true
[[ -z "$(ls -A "$FIX_RUN")" ]] || fail "SIGTERM left the wrapper's scratch directory behind: $(ls -A "$FIX_RUN")"
! grep -q 'STREAM-LAST' "$T/term.out" || fail "SIGTERM did not stop the play"
# SIGHUP (a closed terminal) is forwarded too, and the scratch directory is still removed
( cd / && exec env -i PATH="$PATH" HOME="$FIX_HOME" XDG_RUNTIME_DIR="$FIX_RUN" TMPDIR="$FIX_TMP" HERMES_SECRETS_KEY_FILE="$FIX_KEY" \
    "$FIX_REPO/scripts/deploy" --tags slow >"$T/hup.out" 2>&1 ) &
hpid=$!
for _ in $(seq 1 60); do sleep 0.2; grep -q 'STREAM-FIRST' "$T/hup.out" 2>/dev/null && break; done
kill -HUP "$hpid"; wait "$hpid" || true
[[ -z "$(ls -A "$FIX_RUN")" ]] || fail "SIGHUP left the wrapper's scratch directory behind"
! grep -q 'STREAM-LAST' "$T/hup.out" || fail "SIGHUP did not stop the play"
echo "vetted flags pass through; extra variables, ad-hoc modules, inventories, other playbooks, odd values and unregistered scripts are refused"

# --- Ansible's own file writes are pinned off ------------------------------------------------------------
set_cfg() { printf '%s\n' "$1" >> "$FIX_REPO/ansible.cfg"; }
reset_cfg() { printf '[defaults]\nroles_path = ./roles\nretry_files_enabled = false\nstdout_callback = default\ndeprecation_warnings = False\n' > "$FIX_REPO/ansible.cfg"; rm -rf "$FIX_REPO/callback_plugins" "$T/x.log" "$T/facts"; }
pinned_refusal() {  # pinned_refusal <label> <expected fragment>
  [[ $RC -eq 64 ]] || fail "$1: must be refused (got $RC)"
  grep -q "$2" <<<"$OUT" || fail "$1: refused for the wrong reason (wanted '$2')"
  ! grep -q 'PLAY \[' <<<"$OUT" || fail "$1: the playbook ran"
}
FX_EXTRA_ENV="ANSIBLE_LOG_PATH=$T/x.log" fx_deploy --tags always
pinned_refusal "inherited ANSIBLE_LOG_PATH" 'ANSIBLE_LOG_PATH'; [[ ! -e "$T/x.log" ]] || fail "a log file was created"  # refused before ansible-config even runs
FX_EXTRA_ENV="ANSIBLE_CACHE_PLUGIN=jsonfile" fx_deploy --tags always;           pinned_refusal "inherited fact cache setting" 'ANSIBLE_CACHE_PLUGIN'
FX_EXTRA_ENV="ANSIBLE_CALLBACKS_ENABLED=community.general.log_plays" fx_deploy --tags always;    pinned_refusal "inherited callback setting" 'ANSIBLE_CALLBACKS_ENABLED'
FX_EXTRA_ENV="ANSIBLE_CONFIG=/etc/ansible/ansible.cfg" fx_deploy --tags always; pinned_refusal "inherited config pointer" 'ANSIBLE_CONFIG'
FX_EXTRA_ENV="ANSIBLE_FORCE_COLOR=1" fx_deploy --tags always
[[ $RC -eq 0 ]] && grep -q 'ANSIBLE_FORCE_COLOR' <<<"$OUT" || fail "a harmless inherited ANSIBLE_* setting must be cleared with a note naming it (got $RC)"

reset_cfg; sed -i 's/^\[defaults\]$/[defaults]\nlog_path = '"${T//\//\\/}"'\/x.log/' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "log_path in the repository's ansible.cfg" 'log file'
# (the inspection itself may touch the configured path, creating an EMPTY file; nothing may be written to it)
[[ ! -s "$T/x.log" ]] || fail "a log file with content was created"
reset_cfg; set_cfg 'fact_caching = jsonfile'; set_cfg "fact_caching_connection = $T/facts"
fx_deploy --tags always;  pinned_refusal "persistent fact cache in ansible.cfg" 'fact cache'; [[ -z "$(ls -A "$T/facts" 2>/dev/null)" ]] || fail "a fact cache was created"
reset_cfg; mkdir -p "$FIX_REPO/callback_plugins"
write_logger() {  # a callback plugin that logs every task result to $T/cb-leak
  cat > "$1" <<P
from ansible.plugins.callback import CallbackBase
class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'notification'
    CALLBACK_NAME = 'logger'
    def v2_runner_on_ok(self, result):
        open('$T/cb-leak', 'a').write(str(result._result))
P
}
write_logger "$FIX_REPO/callback_plugins/logger.py"
fx_deploy --tags always;  pinned_refusal "a logging callback plugin in the tree" 'callback_plugins'; [[ ! -e "$T/cb-leak" ]] || fail "the callback ran"
# The config file is parsed against an ALLOWLIST (a denylist over `ansible-config dump` cannot see plugin-level options such
# as [ssh_connection] ssh_executable). Each class below loads or runs code, or writes elsewhere, using a path that is NOT a
# refused directory name (.scratch is skipped by the tree walk), so only the allowlist can be why it is refused.
cfg_case() {  # cfg_case <label> <ini lines...>   (appended after the pristine config)
  local label="$1"; shift
  reset_cfg; printf '%s\n' "$@" >> "$FIX_REPO/ansible.cfg"
  fx_deploy --tags always
  pinned_refusal "$label" 'allowlist'
}
mkdir -p "$FIX_REPO/.scratch/vp" "$FIX_REPO/.scratch/lib"
printf '#!/usr/bin/env bash\nenv > "%s/vault-leak"\necho pw\n' "$T" > "$FIX_REPO/.scratch/vp.sh"; chmod +x "$FIX_REPO/.scratch/vp.sh"
cat > "$FIX_REPO/.scratch/vp/leak.py" <<P
import os
from ansible.plugins.vars import BaseVarsPlugin
class VarsModule(BaseVarsPlugin):
    def get_vars(self, loader, path, entities, cache=True):
        open('$T/vars-cfg-leak', 'a').write(os.environ.get('FIX_TOKEN', ''))
        return {}
P
cfg_case "vars_plugins path in ansible.cfg"       '[defaults]' 'vars_plugins = ./.scratch/vp'
sed -i 's/^\[defaults\]$/[defaults]\nvars_plugins = .\/.scratch\/vp/' "$FIX_REPO/ansible.cfg" 2>/dev/null || true
cfg_case "vault_password_file in ansible.cfg"     '[defaults]' 'vault_password_file = ./.scratch/vp.sh'
cfg_case "ssh_executable in ansible.cfg"          '[ssh_connection]' 'ssh_executable = ./.scratch/x'
cfg_case "library path in ansible.cfg"            '[defaults]' 'library = ./.scratch/lib'
cfg_case "local_tmp in ansible.cfg"               '[defaults]' "local_tmp = $T/lt"
cfg_case "persistent_connection log in ansible.cfg" '[persistent_connection]' "log_messages = true"
cfg_case "unknown section in ansible.cfg"         '[galaxy]' 'server_list = x'
# [DEFAULT] keys are merged into every section and honoured by Ansible: refused as a section of its own
cfg_case "a [DEFAULT] section in ansible.cfg"     '[DEFAULT]' 'vault_password_file = ./.scratch/vp.sh'
cfg_case "a [DEFAULT] section with an allowlisted key" '[DEFAULT]' 'forks = 5'   # only the explicit refusal catches this
cfg_case "interpreter_python in ansible.cfg"      '[defaults]' 'interpreter_python = ./.scratch/py'
reset_cfg; printf '[defaults]\ncollections_paths = ./.scratch/c\n' >> "$FIX_REPO/ansible.cfg"
python3 - "$FIX_REPO/ansible.cfg" <<'E'
import sys; p=sys.argv[1]; t=open(p).read().replace("[defaults]\n","",1).replace("collections_paths = ./.scratch/c\n","",1); open(p,"w").write("[defaults]\ncollections_paths = ./.scratch/c\n"+t)
E
fx_deploy --tags always;  pinned_refusal "an in-repo collections_paths (plural key)" 'pinned locations'
reset_cfg; sed -i 's|^roles_path = ./roles|roles_path = ./roles:|' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "an empty roles_path entry" 'pinned locations'
reset_cfg; sed -i 's|^roles_path = ./roles|roles_path = ./roles\ninventory = ./.scratch/inv|' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "an inventory other than inventory.ini" 'inventory must stay'
reset_cfg; chmod 000 "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "an unreadable ansible.cfg" 'cannot be read'
chmod 600 "$FIX_REPO/ansible.cfg"; reset_cfg
# a repo-local virtualenv (gitignored) is not a plugin location: it must not make the wrapper refuse
mkdir -p "$FIX_REPO/.venv/lib/site-packages/ansible_collections/x"
fx_deploy --tags always;  [[ $RC -eq 0 ]] || fail "a repo-local .venv must not make the wrapper refuse (rc=$RC)"
rm -rf "$FIX_REPO/.venv"
mkdir -p "$FIX_REPO/Vars_Plugins"; fx_deploy --tags always;  pinned_refusal "a plugin directory name in another letter case" 'vars_plugins'; rm -rf "$FIX_REPO/Vars_Plugins"
# search paths that leave the repository
reset_cfg; sed -i 's|^roles_path = ./roles|roles_path = /elsewhere/roles|' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "roles_path outside the repository" 'pinned locations'
reset_cfg; sed -i 's|^roles_path = ./roles|roles_path = ./roles:../other|' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "roles_path entry with .." 'pinned locations'
# an in-repo collections/roles path that only LOOKS harmless (the tree walk skips .scratch) is refused: paths are pinned exactly
mkdir -p "$FIX_REPO/.scratch/c/ansible_collections/hermesfix/demo/plugins/action"
cat > "$FIX_REPO/.scratch/c/ansible_collections/hermesfix/demo/plugins/action/hello.py" <<P
import os
from ansible.plugins.action import ActionBase
class ActionModule(ActionBase):
    def run(self, tmp=None, task_vars=None):
        open('$T/action-leak', 'a').write(os.environ.get('FIX_TOKEN', ''))
        return dict(changed=False, msg='x')
P
reset_cfg; printf '[defaults]\ncollections_path = ./.scratch/c:~/.ansible/collections\n' > "$T/cfg.extra"
python3 - "$FIX_REPO/ansible.cfg" "$T/cfg.extra" <<'E'
import sys
cfg=open(sys.argv[1]).read().replace('[defaults]\n','',1)
open(sys.argv[1],'w').write('[defaults]\ncollections_path = ./.scratch/c:~/.ansible/collections\n'+cfg)
E
fx_deploy --tags always;  pinned_refusal "an in-repo collections_path" 'pinned locations'
reset_cfg; sed -i 's|^roles_path = ./roles|roles_path = ./roles:./.scratch/rolesx|' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "an extra in-repo roles_path" 'pinned locations'
reset_cfg; sed -i 's|^roles_path = ./roles|roles_path = $HOME/roles|' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "a roles_path using an environment variable" 'pinned locations'
# a missing / non-regular / unparseable ansible.cfg would make Ansible fall back to OTHER configuration files: refused
mv "$FIX_REPO/ansible.cfg" "$T/cfg.saved"
fx_deploy --tags always;  pinned_refusal "a missing ansible.cfg" 'missing or is not a regular file'
mkdir "$FIX_REPO/ansible.cfg"; printf '[defaults]\nvault_password_file = ../.scratch/vp.sh\n' > "$FIX_REPO/ansible.cfg/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "ansible.cfg as a directory" 'missing or is not a regular file'
rm -rf "$FIX_REPO/ansible.cfg"
printf '[defaults\nnot ini at all\n' > "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "an unparseable ansible.cfg" 'cannot be read or parsed'
mv -f "$T/cfg.saved" "$FIX_REPO/ansible.cfg"
reset_cfg
[[ ! -e "$T/vault-leak" && ! -e "$T/vars-cfg-leak" && ! -e "$T/action-leak" ]] || fail "a configured plugin/vault/collection code path ran"
rm -rf "$FIX_REPO/.scratch"
# ...and the REAL repository's own ansible.cfg and tree are accepted (no false positive)
python3 - "$ROOT_DIR" <<'E' || fail "the real repository's ansible.cfg/tree is refused by the wrapper's own policy"
import importlib.machinery, importlib.util, os, sys
root = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("deploy_mod", os.path.join(root, "scripts", "deploy"))
spec = importlib.util.spec_from_loader("deploy_mod", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
env = {k: v for k, v in os.environ.items() if not k.startswith(("ANSIBLE_", "_ANSIBLE_"))}
env["ANSIBLE_CONFIG"] = os.path.join(root, "ansible.cfg")
assert mod.python_supported((3, 11, 0)) and mod.python_supported((3, 14, 1)) and not mod.python_supported((3, 10, 9)), "python version guard"
problems = mod.effective_config_problems(root, env, {})
if problems:
    print("\n".join(problems)); sys.exit(1)
E
# every directory Ansible auto-loads code from is refused, at the top level and inside a role
for d in vars_plugins action_plugins filter_plugins lookup_plugins connection_plugins strategy_plugins inventory_plugins \
         cache_plugins test_plugins become_plugins shell_plugins terminal_plugins httpapi_plugins netconf_plugins cliconf_plugins library module_utils doc_fragments collections ansible_collections; do
  reset_cfg; mkdir -p "$FIX_REPO/$d"
  fx_deploy --tags always;  pinned_refusal "a $d directory in the tree" "$d"
  rm -rf "$FIX_REPO/$d"
done
reset_cfg; mkdir -p "$FIX_REPO/roles/secrets/vars_plugins"
fx_deploy --tags always;  pinned_refusal "a vars_plugins directory inside a role" 'vars_plugins'
rm -rf "$FIX_REPO/roles/secrets/vars_plugins"
# a callback allowlisted by name but from a NON-builtin collection could be shadowed by a repository collection
reset_cfg; sed -i 's/^\[defaults\]$/[defaults]\ncallbacks_enabled = ansible.posix.profile_tasks/' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "a non-builtin callback name" 'ansible.builtin names only'
reset_cfg; sed -i 's/^stdout_callback = default$/stdout_callback = community.general.yaml/' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "a non-builtin stdout callback" 'stdout callback'
# ...also when it is a SYMLINK (os.walk lists but never visits those) or lives under a role
reset_cfg; mkdir -p "$T/evil"; write_logger "$T/evil/logger.py"; ln -s "$T/evil" "$FIX_REPO/callback_plugins"
fx_deploy --tags always;  pinned_refusal "a symlinked callback_plugins" 'callback_plugins'; [[ ! -e "$T/cb-leak" ]] || fail "the symlinked callback ran"
reset_cfg; mkdir -p "$FIX_REPO/roles/secrets/callback_plugins"
fx_deploy --tags always;  pinned_refusal "a callback_plugins directory inside a role" 'callback_plugins'
reset_cfg; rm -rf "$FIX_REPO/roles/secrets/callback_plugins"
# a logging callback in the USER's plugin directory auto-loads unless the wrapper pins it away
reset_cfg; mkdir -p "$FIX_HOME/.ansible/plugins/callback"; write_logger "$FIX_HOME/.ansible/plugins/callback/logger.py"
fx_deploy --tags always
[[ $RC -eq 0 ]] || fail "a plugin in ~/.ansible must not stop the run (it is simply not loaded) (rc=$RC)"
[[ ! -e "$T/cb-leak" ]] || fail "a callback plugin under ~/.ansible logged task results (the wrapper must pin ANSIBLE_HOME away)"
rm -rf "$FIX_HOME/.ansible/plugins"
# ANSIBLE_HOME is pinned away from ~/.ansible for EVERY plugin type, not just callbacks: a vars plugin there auto-runs
mkdir -p "$FIX_HOME/.ansible/plugins/vars"
cat > "$FIX_HOME/.ansible/plugins/vars/leak.py" <<P
import os
from ansible.plugins.vars import BaseVarsPlugin
class VarsModule(BaseVarsPlugin):
    def get_vars(self, loader, path, entities, cache=True):
        open('$T/vars-leak', 'a').write(os.environ.get('FIX_TOKEN', ''))
        return {}
P
fx_deploy --tags always
[[ $RC -eq 0 ]] || fail "a vars plugin in ~/.ansible must not stop the run (rc=$RC)"
[[ ! -e "$T/vars-leak" ]] || fail "a vars plugin under ~/.ansible ran inside the deployment (ANSIBLE_HOME must be pinned away)"
rm -rf "$FIX_HOME/.ansible/plugins"
reset_cfg; sed -i 's/^\[defaults\]$/[defaults]\ncallback_plugins = .\/cb/' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "a callback plugin path in ansible.cfg" 'callback plugin path'
# retry files would hold the target host: pinned off through the environment even if the config enables them
# (a retry_files_save_path is not on the config allowlist at all)
reset_cfg; sed -i "s/^retry_files_enabled = false/retry_files_enabled = true/" "$FIX_REPO/ansible.cfg"
fx_deploy --tags failing
[[ $RC -eq 2 ]] || fail "the failing play should still fail with 2 (got $RC)"
[[ -z "$(find "$FIX_REPO" "$FIX_HOME" "$FIX_TMP" -name '*.retry' 2>/dev/null)" ]] || fail "a retry file (holding the target host) was written"
reset_cfg; sed -i 's/^\[defaults\]$/[defaults]\ncallbacks_enabled = community.general.log_plays/' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "a logging callback enabled in ansible.cfg" 'callback'
reset_cfg; sed -i 's/^stdout_callback = default$/stdout_callback = ansible.posix.json/' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  pinned_refusal "a non-allowlisted stdout callback" 'stdout callback'
reset_cfg; sed -i 's/^\[defaults\]$/[defaults]\ncallbacks_enabled = timer/' "$FIX_REPO/ansible.cfg"
fx_deploy --tags always;  [[ $RC -eq 0 ]] || fail "a print-only allowlisted callback (timer) must be accepted (got $RC)"
reset_cfg
fx_deploy --tags always;  [[ $RC -eq 0 ]] || fail "the pristine configuration must be accepted again (got $RC)"
# the inspection must FAIL CLOSED (ansible-config broken/garbled -> refused) and must never see the secrets
REAL_CFG="$(command -v ansible-config)"; mkdir -p "$T/stub"
cat > "$T/stub/ansible-config" <<STUB
#!/usr/bin/env bash
env > "$T/inspect-env"
case "\${STUB_MODE:-pass}" in
  fail)    echo "[]"; echo "boom" >&2; exit 1 ;;   # plausible-looking output but a failure status
  garbage) echo "not json"; exit 0 ;;
esac
exec "$REAL_CFG" "\$@"
STUB
# the wrapper resolves ansible-config next to ansible-playbook (so both belong to the same install): a stub
# ansible-playbook that just forwards puts the stub ansible-config in the same directory
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$(command -v ansible-playbook)" > "$T/stub/ansible-playbook"
chmod +x "$T/stub/ansible-config" "$T/stub/ansible-playbook"
FX_PATH="$T/stub:$PATH" FX_EXTRA_ENV="STUB_MODE=fail" fx_deploy --tags always
[[ $RC -eq 64 ]] && grep -q 'cannot inspect' <<<"$OUT" && ! grep -q 'PLAY \[' <<<"$OUT" || fail "a failing config inspection must refuse the run (rc=$RC)"
FX_PATH="$T/stub:$PATH" FX_EXTRA_ENV="STUB_MODE=garbage" fx_deploy --tags always
[[ $RC -eq 64 ]] && grep -q 'cannot inspect' <<<"$OUT" || fail "an unparseable config inspection must refuse the run (rc=$RC)"
# ansible-config is taken from the same install as ansible-playbook, not whichever is first on PATH
mkdir -p "$T/stub2"; printf '#!/usr/bin/env bash\necho "[]"; exit 1\n' > "$T/stub2/ansible-config"; chmod +x "$T/stub2/ansible-config"
FX_PATH="$T/stub2:$T/stub:$PATH" fx_deploy --tags always
[[ $RC -eq 0 ]] || fail "ansible-config must be resolved next to ansible-playbook, not from an earlier PATH entry (rc=$RC)"
rm -f "$T/inspect-env"
FX_PATH="$T/stub:$PATH" fx_deploy --tags always
[[ $RC -eq 0 && -f "$T/inspect-env" ]] || fail "the inspection did not run in the normal case (rc=$RC)"
for canary in "$CANARY_TOKEN" "$CANARY_DOMAIN" "$CANARY_UNICODE" "$CANARY_SHORT" "$CANARY_SPECIAL" "$CANARY_QUOTES"; do
  ! grep -qF -- "$canary" "$T/inspect-env" || fail "the decrypted secrets were in the environment of the configuration inspection"
done
echo "Ansible file writes are pinned off: inherited settings, ansible.cfg log/cache/callback settings and callback_plugins dirs are each refused; print-only callbacks pass"

# --- preflight: clear failures, by name only, before anything runs ---------------------------------------
NOKEY="$T/keys/none.txt"
FIX_KEY_OVERRIDE="$NOKEY" fx_deploy --tags always
[[ $RC -eq 78 ]] && grep -q 'age key is missing' <<<"$OUT" && ! grep -q 'PLAY \[' <<<"$OUT" || fail "a missing key must stop the run before anything runs (rc=$RC)"
cp "$FIX_KEY" "$T/keys/loose.txt"; chmod 644 "$T/keys/loose.txt"
FIX_KEY_OVERRIDE="$T/keys/loose.txt" fx_deploy --tags always
[[ $RC -eq 78 ]] && grep -q 'accessible to other users' <<<"$OUT" || fail "a group/world-readable key must be refused (rc=$RC)"
chmod 640 "$T/keys/loose.txt"; FIX_KEY_OVERRIDE="$T/keys/loose.txt" fx_deploy --tags always
[[ $RC -eq 78 ]] || fail "a group-readable key must be refused (rc=$RC)"
age-keygen -o "$T/keys/other.txt" >/dev/null 2>&1; chmod 600 "$T/keys/other.txt"
FIX_KEY_OVERRIDE="$T/keys/other.txt" fx_deploy --tags always
[[ $RC -eq 78 ]] && grep -q 'cannot decrypt' <<<"$OUT" || fail "a key that is not a recipient must fail preflight (rc=$RC)"
mv "$FIX_REPO/secrets/secrets.enc.env" "$T/store.bak"
fx_deploy --tags always;  [[ $RC -eq 78 ]] && grep -q 'store is missing' <<<"$OUT" || fail "a missing store must fail preflight (rc=$RC)"
head -c 60 "$T/store.bak" > "$FIX_REPO/secrets/secrets.enc.env"
fx_deploy --tags always;  [[ $RC -eq 78 ]] && grep -q 'cannot decrypt' <<<"$OUT" || fail "a corrupt store must fail preflight (rc=$RC)"
mv "$T/store.bak" "$FIX_REPO/secrets/secrets.enc.env"
# a store missing required names: reported by NAME only, never a value
printf 'TARGET_HOST=%s\nFIX_TOKEN=%s\n' "$CANARY_HOST" "$CANARY_TOKEN" > "$T/plain/partial.env"
fx_encrypt "$T/plain/partial.env" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
fx_deploy --tags always
[[ $RC -eq 78 ]] || fail "a store missing required names must fail preflight (rc=$RC)"
grep -q 'FIX_DOMAIN' <<<"$OUT" && grep -q 'FIX_UNICODE' <<<"$OUT" && grep -q 'FIX_SHORT' <<<"$OUT" || fail "the missing names were not all reported"
! grep -qE "$CANARY_TOKEN|$CANARY_HOST" <<<"$OUT" || fail "a preflight message printed a value"
! grep -q 'PLAY \[' <<<"$OUT" || fail "the playbook ran despite missing required secrets"
# no target host in the store
printf 'FIX_TOKEN=x\nFIX_DOMAIN=x\nFIX_UNICODE=x\nFIX_SHORT=x\nFIX_SPECIAL=x\nFIX_CONTAINER=x\n' > "$T/plain/nohost.env"
fx_encrypt "$T/plain/nohost.env" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
fx_deploy --tags always;  [[ $RC -eq 78 ]] && grep -q 'TARGET_HOST' <<<"$OUT" || fail "a store without TARGET_HOST must fail preflight naming it (rc=$RC)"
fx_encrypt "$FIX_PLAIN" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
# tools missing: a PATH with python but no sops/age
mkdir -p "$T/nobin"; ln -sf "$(command -v python3)" "$T/nobin/python3"; ln -sf "$(command -v env)" "$T/nobin/env"
set +e; OUT="$(cd / && env -i PATH="$T/nobin" HOME="$FIX_HOME" HERMES_SECRETS_KEY_FILE="$FIX_KEY" "$FIX_REPO/scripts/deploy" --tags always 2>&1)"; RC=$?; set -e
[[ $RC -eq 78 ]] && grep -q 'sops is not installed' <<<"$OUT" && grep -q 'age is not installed' <<<"$OUT" || fail "missing sops/age must be reported (rc=$RC)"
# the store may not inject names that change how the child runs, and TARGET_HOST must be a plain host
printf 'TARGET_HOST=%s\nFIX_TOKEN=x\nFIX_DOMAIN=x\nFIX_UNICODE=x\nFIX_SHORT=x\nFIX_SPECIAL=x\nFIX_CONTAINER=x\nANSIBLE_LOG_PATH=/x\nPATH=/x\nHOME=/x\nLD_PRELOAD=/x\nPYTHONPATH=/x\nSSH_AUTH_SOCK=/x\nHTTPS_PROXY=/x\nNOT_IN_THE_MANIFEST=1\n' "$CANARY_HOST" > "$T/plain/reserved.env"
fx_encrypt "$T/plain/reserved.env" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
fx_deploy --tags always
[[ $RC -eq 78 ]] && ! grep -q 'PLAY \[' <<<"$OUT" || fail "names outside the manifest and the declared extras must fail preflight (rc=$RC)"
for n in ANSIBLE_LOG_PATH PATH HOME LD_PRELOAD PYTHONPATH SSH_AUTH_SOCK HTTPS_PROXY NOT_IN_THE_MANIFEST; do
  grep -qw -- "$n" <<<"$OUT" || fail "the undeclared name $n was not reported"
done
printf 'TARGET_HOST=%s\nFIX_TOKEN=\nFIX_DOMAIN=x\nFIX_UNICODE=x\nFIX_SHORT=x\nFIX_SPECIAL=x\nFIX_CONTAINER=x\n' "$CANARY_HOST" > "$T/plain/empty.env"
fx_encrypt "$T/plain/empty.env" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
fx_deploy --tags always;  [[ $RC -eq 78 ]] && grep -q 'FIX_TOKEN' <<<"$OUT" || fail "an EMPTY required value must count as missing (rc=$RC)"
printf 'TARGET_HOST=-oProxyCommand=id\nFIX_TOKEN=x\nFIX_DOMAIN=x\nFIX_UNICODE=x\nFIX_SHORT=x\nFIX_SPECIAL=x\nFIX_CONTAINER=x\n' > "$T/plain/badhost.env"
fx_encrypt "$T/plain/badhost.env" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
fx_deploy --tags always;  [[ $RC -eq 78 ]] && grep -q 'TARGET_HOST' <<<"$OUT" && ! grep -q 'PLAY \[' <<<"$OUT" || fail "an odd TARGET_HOST must fail preflight (rc=$RC)"
for badhost in '-host' 'localhost\n' 'a b'; do
  printf 'TARGET_HOST=%s\nFIX_TOKEN=x\nFIX_DOMAIN=x\nFIX_UNICODE=x\nFIX_SHORT=x\nFIX_SPECIAL=x\nFIX_CONTAINER=x\n' "$badhost" > "$T/plain/badhost2.env"
  fx_encrypt "$T/plain/badhost2.env" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
  fx_deploy --tags always;  [[ $RC -eq 78 ]] && grep -q 'TARGET_HOST' <<<"$OUT" && ! grep -q 'PLAY \[' <<<"$OUT" || fail "TARGET_HOST '$badhost' must fail preflight (rc=$RC)"
done
fx_encrypt "$FIX_PLAIN" "$FIX_REPO/secrets/secrets.enc.env" "$FIX_PUB"
# the wrapper must never echo sops' own text: pointed at a file that is not a store, sops names the offending LINE
printf 'SECRETLINE-xyz789\nsecond line\n' > "$T/plain/notastore.txt"
printf '\xff\xfe\x00\x80binary-xyz789' > "$T/plain/binstore.bin"      # not UTF-8: must still be a clean "cannot decrypt"
for target in "$FIX_KEY" "$T/plain/notastore.txt" "$T/plain/binstore.bin"; do
  FX_EXTRA_ENV="HERMES_SECRETS_STORE=$target" fx_deploy --tags always
  [[ $RC -eq 78 ]] && grep -q 'cannot decrypt' <<<"$OUT" || fail "a non-store file must fail preflight (rc=$RC)"
  ! grep -qE 'AGE-SECRET-KEY|SECRETLINE|xyz789' <<<"$OUT" || fail "sops' text (a key or a plaintext line) was echoed by preflight"
done
echo "preflight: missing/loose/foreign key, missing/corrupt store, missing required names (by name only) and missing tools each stop the run before anything runs"

# --- a leftover plaintext .env: warned about, never used -------------------------------------------------
printf 'FIX_TOKEN=leftover-should-be-ignored\n' > "$FIX_REPO/.env"
fx_deploy --tags always
[[ $RC -eq 0 ]] && grep -q 'plaintext .env' <<<"$OUT" || fail "a leftover .env must produce a warning (rc=$RC)"
rm -f "$FIX_REPO/.env"
echo "a leftover plaintext .env produces a warning and is ignored"

# --- the store's location is configurable; recipients: one key per workstation plus break-glass ----------
mkdir -p "$T/elsewhere"
age-keygen -o "$T/keys/breakglass.txt" >/dev/null 2>&1; chmod 600 "$T/keys/breakglass.txt"
BG_PUB="$(age-keygen -y "$T/keys/breakglass.txt")"
fx_encrypt "$FIX_PLAIN" "$T/elsewhere/store.enc.env" "$FIX_PUB" "$BG_PUB"
mv "$FIX_REPO/secrets/secrets.enc.env" "$T/store.moved"
FX_EXTRA_ENV="HERMES_SECRETS_STORE=$T/elsewhere/store.enc.env" fx_deploy --tags always
[[ $RC -eq 0 ]] && grep -q 'RESOLVER OK' <<<"$OUT" || fail "a store at a non-default path (HERMES_SECRETS_STORE) must work (rc=$RC)"
FX_EXTRA_ENV="HERMES_SECRETS_STORE=$T/elsewhere/store.enc.env" FIX_KEY_OVERRIDE="$T/keys/breakglass.txt" fx_deploy --tags always
[[ $RC -eq 0 ]] && grep -q 'RESOLVER OK' <<<"$OUT" || fail "the break-glass key (a second recipient) must decrypt the same store (rc=$RC)"
FX_EXTRA_ENV="HERMES_SECRETS_STORE=$T/elsewhere/store.enc.env" fx_deploy --script show-env
grep -q 'KEY SOURCE NOT EXPOSED' <<<"$OUT" || fail "HERMES_SECRETS_STORE was passed on to the child"
mv "$T/store.moved" "$FIX_REPO/secrets/secrets.enc.env"
echo "store location is configurable; a store with a workstation key and a break-glass key decrypts with either"

# --- the SOPS configuration scopes recipients to the store's path -----------------------------------------
if ( cd "$FIX_REPO" && sops encrypt --filename-override some/other.env --input-type dotenv --output-type dotenv "$FIX_PLAIN" >/dev/null 2>&1 ); then
  fail "the SOPS configuration must not apply its recipients to files outside the store's path"
fi
( cd "$FIX_REPO" && sops encrypt --filename-override secrets/secrets.enc.env --input-type dotenv --output-type dotenv "$FIX_PLAIN" >/dev/null 2>&1 ) \
  || fail "the SOPS configuration must apply to the store's own path"
echo ".sops.yaml recipients are scoped to the store's path"

# --- the real repository: nothing decrypted is ever written by this guard --------------------------------
[[ -x scripts/deploy && -f scripts/registered-scripts.conf ]] || fail "scripts/deploy and scripts/registered-scripts.conf must exist"
echo "deploy wrapper guard OK"

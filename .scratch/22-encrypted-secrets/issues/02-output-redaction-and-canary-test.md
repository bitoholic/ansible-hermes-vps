# 02: Output redaction, proven by a canary test

**What to build:** Everything the deploy wrapper prints — in both modes — has every decrypted value masked, and a test proves it by deliberately trying to leak canary values through the known paths, including the awkward ones (a value split across output chunks, non-ASCII JSON escaping, short common values), and finding none of them in the output.

**Blocked by:** #01
**Blocks:** #09

**Status:** done

- [x] Every decrypted value of at least four characters (a fixed, documented constant) is masked in both stdout and stderr, matched literally and in its JSON-escaped (including non-ASCII escapes) and URL-encoded forms
- [x] A canary test drives a fixture playbook that emits canary values through a debug message, a rendered template diff and verbose task arguments at maximum verbosity, and asserts no canary appears anywhere in the combined output
- [x] **Chunk boundaries:** a canary split across output-read or line-buffer boundaries is still masked (the redactor works on a stream with carry-over, not line by line)
- [x] **Non-ASCII:** a canary containing non-ASCII characters, which JSON escapes as `\u` sequences, is masked in its escaped form
- [x] **Short common values:** a short value at the minimum length is masked, and the over-redaction this causes for common words is a documented, accepted trade-off
- [x] A value that contains another value is masked completely, leaving no readable fragment
- [x] Streaming behavior and exit status are unaffected by redaction, in playbook mode and script mode
- [x] The test needs no real key or secret (throwaway key and fixture store)
- [x] The documented limits state that other encodings (for example base64) are not covered and that source-level suppression (#05) is the complement

## Notes

See epic 22 spec, "Implementation Decisions" (output redaction) and "Further Notes" (the biggest leak vector is output, not storage).

## Implementation notes

**Deliverables.** `scripts/hermes_redact.py` (the redactor; ticket #01 fixed its seam), the wiring in `scripts/deploy` (unchanged from #01: a fresh redactor per stream, fed every decrypted value), and the canary test inside `tests/check-deploy-wrapper.sh` with an extended fixture (`tests/support/deploy-fixture.sh`: a canary-emitting play tagged `leak`, a template, and scripts that split values across reads). No new lint wiring — the wrapper guard is already in the standard run.

**How it works.** For every decrypted value of at least `MIN_REDACT_LEN` (4) characters the redactor builds the byte strings under which it may appear — literal; JSON (default `\uXXXX` form in both hex cases, raw UTF-8, with and without `\/`); Python `repr`-style (quotes and backslashes escaped); URL-encoded (both hex cases, `quote`, `quote_plus`) — and masks every occurrence with `[redacted]` in stdout and stderr. It works on a **byte stream with carry-over**: after each chunk only the tail that could be the *beginning* of a value is held back (so ordinary output is not delayed and a line never waits for more output), and it is flushed — masked — at the end of the stream. Matches from all needles are collected **including overlaps** and merged, so a value that contains another value, or overlaps one, leaves no readable fragment of either. A redactor failure withholds the stream but keeps draining (the child never blocks). Performance: 5 MB of output in ~0.15 s.

**The canary test (black box, fixture only).** Independent of the implementation, a Python *oracle* computes every form a value may take (plain, JSON with and without `\u` escapes, repr, URL-encoded in both hex cases) and the test asserts **none appears anywhere in the combined output** of: a debug message; `to_json` and `urlencode` renderings (non-ASCII becomes `\u` sequences); a template diff (`--check --diff`); verbose task arguments and results at `-vvvvvv` (and at `-vvv` and default verbosity); a value that contains another value; two values that overlap in the output; and — in script mode — every value, in plain, JSON and repr forms, **split at every position across two separate writes** (a pause forces two reads), to both stdout and stderr. Markers prove each leaking task really ran (no vacuous pass). Also asserted: a value below the minimum length is deliberately **not** masked (pins the constant); the held-back tail is flushed at the end of a stream (both an incomplete prefix, unmasked, and a whole value that is a prefix of a longer one, masked); the target host is itself masked, so `ok: [[redacted]]` in the play recap is now the proof that the play targeted the host from the store.

**Mutation-checked.** Minimum length ±1, dropping JSON/URL variants, no carry-over, no cut-through protection, dropping or not masking the final flush, redaction disabled on stdout / on stderr / for all values, ASCII-only JSON — all caught. Equivalent mutants (documented as such): dropping only the `repr` variant (the explicit quote-escaping variants cover it), dropping only one of the three JSON adds, and disabling overlap merging (cross-value overlaps are still fully masked — as two adjacent masks — because each value is found independently).

**Documented limits (also in the module docstring).** Other encodings — base64, hex, ROT13, a value split by the program's own formatting, one character at a time — are **not** covered; source-level suppression (#05) is the complement. Values shorter than four characters are not redacted (masking them would hide half of every log); a value *at* four characters is, and the resulting over-redaction of a common word is an accepted trade-off — hiding too much is the safe failure mode. The wrapper's *own* diagnostics (preflight messages, refusals) name secrets by name only and are not passed through the redactor.

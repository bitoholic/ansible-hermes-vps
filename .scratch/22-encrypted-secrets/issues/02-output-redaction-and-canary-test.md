# 02: Output redaction, proven by a canary test

**What to build:** Everything the deploy wrapper prints has every decrypted value masked, and a test proves it by deliberately trying to leak canary values through the three known paths — a debug message, a rendered diff and verbose task arguments — and finding none of them in the output.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] Every decrypted value at or above a minimum length (default four characters, configurable) is masked in both stdout and stderr, matched literally and in its JSON-escaped and URL-encoded forms
- [ ] A canary test drives a fixture playbook that emits canary values through a debug message, a rendered template diff and verbose task arguments at maximum verbosity, and asserts no canary appears anywhere in the combined output
- [ ] A value that contains another value is masked completely, leaving no readable fragment
- [ ] Streaming behavior and exit status are unaffected by redaction
- [ ] The test needs no real key or secret (throwaway key and fixture store)
- [ ] The documented limits state that other encodings (for example base64) are not covered and that source-level suppression (#05) is the complement, and that over-redaction of short common values is accepted as the safe failure mode

## Notes

See epic 22 spec, "Implementation Decisions" (output redaction) and "Further Notes" (the biggest leak vector is output, not storage).

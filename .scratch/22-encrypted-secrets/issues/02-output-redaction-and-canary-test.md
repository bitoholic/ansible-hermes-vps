# 02: Output redaction, proven by a canary test

**What to build:** Everything the deploy wrapper prints — in both modes — has every decrypted value masked, and a test proves it by deliberately trying to leak canary values through the known paths, including the awkward ones (a value split across output chunks, non-ASCII JSON escaping, short common values), and finding none of them in the output.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] Every decrypted value of at least four characters (a fixed, documented constant) is masked in both stdout and stderr, matched literally and in its JSON-escaped (including non-ASCII escapes) and URL-encoded forms
- [ ] A canary test drives a fixture playbook that emits canary values through a debug message, a rendered template diff and verbose task arguments at maximum verbosity, and asserts no canary appears anywhere in the combined output
- [ ] **Chunk boundaries:** a canary split across output-read or line-buffer boundaries is still masked (the redactor works on a stream with carry-over, not line by line)
- [ ] **Non-ASCII:** a canary containing non-ASCII characters, which JSON escapes as `\u` sequences, is masked in its escaped form
- [ ] **Short common values:** a short value at the minimum length is masked, and the over-redaction this causes for common words is a documented, accepted trade-off
- [ ] A value that contains another value is masked completely, leaving no readable fragment
- [ ] Streaming behavior and exit status are unaffected by redaction, in playbook mode and script mode
- [ ] The test needs no real key or secret (throwaway key and fixture store)
- [ ] The documented limits state that other encodings (for example base64) are not covered and that source-level suppression (#05) is the complement

## Notes

See epic 22 spec, "Implementation Decisions" (output redaction) and "Further Notes" (the biggest leak vector is output, not storage).

"""Output redaction for the deploy wrapper (epic 22 ticket #02).

Every decrypted value of at least MIN_REDACT_LEN characters is replaced by MASK in everything the wrapper prints,
whatever form it takes there:

  * literally;
  * JSON-escaped, both the default form (non-ASCII as \\uXXXX, lower- and upper-case hex) and the raw-UTF-8 form,
    with and without `\\/` for a slash — Ansible prints results as JSON;
  * as Python's repr() shows it (quotes and backslashes escaped) — Ansible also prints Python-ish structures;
  * URL-encoded (percent-encoding in both hex cases, and the `+` form for spaces).

The redactor works on a BYTE STREAM with carry-over, not line by line: a value split across two reads (or two
lines) is still found, because the tail of the buffer that could be the start of a value is held back until the next
chunk (or `finish()`). Only such a tail is held, so ordinary output is not delayed. Overlapping and nested matches
are merged, so a value that contains another value (or overlaps one) leaves no readable fragment of either — including
across chunk boundaries and inside a very long run of matches (see `_forced`).

  * JSON text *inside* a JSON string (Ansible prints a `to_json` result, or any JSON a command returned, as a JSON string
    value): the escaping is applied up to three levels deep, in every mix of the ASCII and raw-UTF-8 forms.

Documented limits (the complement is suppression at the source, ticket #05):
  * other encodings are NOT covered — base64, hex, ROT13, JSON nested more than three levels, double URL-encoding
    (`%2540`), JavaScript's `encodeURIComponent` (which leaves `!'()*` unescaped), mixed-case or partial percent-encoding,
    HTML/XML entities, cross-encodings such as JSON inside a URL, shell quoting, YAML quoting, a multi-line value shown
    with per-line prefixes (`--diff` prints `+line1` / `+line2`, so the newline-joined value never matches), a value
    split by the program's own formatting, or a value printed one character at a time;
  * values shorter than MIN_REDACT_LEN are not redacted (a one- or two-character value would mask half of every
    log); a value AT the minimum is, and the over-redaction this causes for a common word is an accepted trade-off:
    the safe failure mode is to hide too much, not too little.
"""
import json
import re
import urllib.parse

MIN_REDACT_LEN = 4
MASK = b"[redacted]"


def _lower_hex_escapes(text):
    return re.sub(r"%[0-9A-Fa-f]{2}", lambda m: m.group(0).lower(), text)


def _upper_unicode_escapes(text):
    return re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: "\\u" + m.group(1).upper(), text)


MAX_JSON_NESTING = 3


def _json_forms(value):
    """The value JSON-string-escaped 1..MAX_JSON_NESTING times, in every mix of ensure_ascii True/False per level."""
    forms, level = set(), {value}
    for _ in range(MAX_JSON_NESTING):
        nxt = set()
        for text in level:
            for ensure_ascii in (True, False):
                nxt.add(json.dumps(text, ensure_ascii=ensure_ascii)[1:-1])
        forms |= nxt
        level = nxt
    return forms


def variants(value):
    """Every byte string under which `value` may appear in program output."""
    out = {value}
    for as_json in _json_forms(value):
        out.add(as_json)
        out.add(as_json.replace("/", "\\/"))
        out.add(_upper_unicode_escapes(as_json))
        out.add(repr(as_json)[1:-1])                                # a JSON string shown by Python's repr
    out.add(repr(value)[1:-1])
    out.add(value.replace("\\", "\\\\").replace("'", "\\'"))     # repr() of a str that is shown single-quoted
    out.add(value.replace("\\", "\\\\").replace('"', '\\"'))     # ... and double-quoted
    raw = value.encode("utf-8", "surrogateescape")      # (a lone surrogate must not crash the constructor)
    for quoted in (urllib.parse.quote_from_bytes(raw, safe=""), urllib.parse.quote_from_bytes(raw, safe="/"),
                   urllib.parse.quote_from_bytes(raw, safe="").replace("%20", "+"),
                   urllib.parse.quote_from_bytes(raw, safe="/").replace("%20", "+")):
        out.add(quoted)
        out.add(_lower_hex_escapes(quoted))
    return {v.encode("utf-8", "replace") for v in out if v}


class StreamRedactor:
    """Feed raw byte chunks; get back bytes that are safe to print. Call finish() at end of stream."""

    def __init__(self, values):
        needles = set()
        for value in values:
            if isinstance(value, str) and len(value) >= MIN_REDACT_LEN:
                needles |= variants(value)
        self._needles = sorted(needles, key=len, reverse=True)
        self._maxlen = max((len(n) for n in self._needles), default=1)
        self._buf = b""
        # Leading bytes of the carry that belong to a run of matches whose head was already emitted as a mask. Those
        # bytes must be masked even if nothing extends the run, because the matches that covered them are no longer
        # in the buffer to be found again.
        self._forced = 0

    def _spans(self, buf):
        """Merged [start, end) intervals of every needle occurrence in `buf`, overlaps included."""
        spans = [(0, self._forced)] if self._forced else []
        for needle in self._needles:
            pos = buf.find(needle)
            while pos != -1:
                spans.append((pos, pos + len(needle)))
                pos = buf.find(needle, pos + 1)
        if not spans:
            return []
        spans.sort()
        merged = [list(spans[0])]
        for start, end in spans[1:]:
            if start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        return merged

    def _held_suffix(self, buf):
        """Length of the longest tail of `buf` that could be the beginning of a needle (so it must wait)."""
        held = 0
        if not buf:
            return held
        last = buf[-1]
        for needle in self._needles:
            for k in range(min(len(needle) - 1, len(buf)), held, -1):
                if needle[k - 1] == last and buf.endswith(needle[:k]):
                    held = k
                    break
        return held

    @staticmethod
    def _apply(buf, spans, limit):
        """`buf[:limit]` with every span that lies inside it replaced by the mask."""
        out, pos = [], 0
        for start, end in spans:
            if end > limit:
                break
            out.append(buf[pos:start])
            out.append(MASK)
            pos = end
        out.append(buf[pos:limit])
        return b"".join(out)

    def feed(self, chunk):
        buf = self._buf + chunk
        spans = self._spans(buf)
        safe_end = len(buf) - self._held_suffix(buf)
        forced = max(0, self._forced - safe_end)
        for i, (start, end) in enumerate(spans):              # never cut through a match ...
            if start < safe_end < end:
                if safe_end - start > 2 * self._maxlen:
                    # ... except that a very long merged run (a value-shaped run of output such as `aaaa…`) must not make
                    # the buffer grow without bound and stall all output. Every byte of it is masked, so emit the part up
                    # to the held tail as one mask and carry only the tail — of which the bytes still inside the run are
                    # FORCED to be masked (their matches are gone from the buffer), whether or not the run continues.
                    spans[i] = (start, safe_end)
                    forced = end - safe_end
                else:
                    safe_end = start
                    forced = max(0, self._forced - safe_end)
                break
        self._buf = buf[safe_end:]
        self._forced = forced
        return self._apply(buf, spans, safe_end)

    def finish(self):
        buf, self._buf = self._buf, b""
        try:
            return self._apply(buf, self._spans(buf), len(buf))
        finally:
            self._forced = 0

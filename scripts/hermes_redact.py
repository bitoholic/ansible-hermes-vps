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
are merged, so a value that contains another value (or overlaps one) leaves no readable fragment of either.

Documented limits (the complement is suppression at the source, ticket #05):
  * other encodings are NOT covered — base64, hex, ROT13, a value split by the program's own formatting, or a value
    printed one character at a time;
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


def variants(value):
    """Every byte string under which `value` may appear in program output."""
    out = {value}
    for ensure_ascii in (True, False):
        as_json = json.dumps(value, ensure_ascii=ensure_ascii)[1:-1]
        out.add(as_json)
        out.add(as_json.replace("/", "\\/"))
        out.add(_upper_unicode_escapes(as_json))
    out.add(repr(value)[1:-1])
    out.add(value.replace("\\", "\\\\").replace("'", "\\'"))     # repr() of a str that is shown single-quoted
    out.add(value.replace("\\", "\\\\").replace('"', '\\"'))     # ... and double-quoted
    for quoted in (urllib.parse.quote(value, safe=""), urllib.parse.quote(value, safe="/"),
                   urllib.parse.quote_plus(value), urllib.parse.quote_plus(value, safe="/")):
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
        self._buf = b""

    def _spans(self, buf):
        """Merged [start, end) intervals of every needle occurrence in `buf`, overlaps included."""
        spans = []
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
        for start, end in spans:              # never cut through a match
            if start < safe_end < end:
                safe_end = start
        self._buf = buf[safe_end:]
        return self._apply(buf, spans, safe_end)

    def finish(self):
        buf, self._buf = self._buf, b""
        return self._apply(buf, self._spans(buf), len(buf))

"""Output redaction for the deploy wrapper.

Ticket #01 fixes the seam (a per-stream object fed raw byte chunks, returning bytes that are safe to
print, with a final flush at end of stream). Ticket #02 replaces the body with the real masking; until
then this passes bytes through unchanged.
"""


class StreamRedactor:
    def __init__(self, values):
        self._values = list(values)

    def feed(self, chunk):
        return chunk

    def finish(self):
        return b""

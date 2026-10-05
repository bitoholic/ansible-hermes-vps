"""Shared history-scrubbing logic for scripts/export-public.py (epic 24 ticket #04, reworked after
the operator asked for a history-preserving export instead of a single flattened snapshot — see
ADR-0009). One function, `scrub_bytes`, is reused unchanged for both file content (git-filter-repo's
--blob-callback) and commit/tag messages (--message-callback), so there is exactly one place this
substitution logic lives rather than two copies that could drift apart.

Holds no secret value itself. `export-public.py` has the decrypted secrets (it runs through
scripts/deploy --script export-public) and builds the literal substitution list and the generic rules'
exempt sets from them; this module only ever receives already-built, plain data.
"""
import re


def scrub_bytes(data, literal_pairs, generic_rules):
    """literal_pairs: [(old_bytes, new_bytes), ...]. generic_rules: [(compiled_pattern,
    placeholder_bytes, exempt_set_of_bytes), ...] — a match equal to something in its own exempt set (a
    functional constant, a known-safe test-fixture value) is left untouched; every other match becomes
    the placeholder.

    literal_pairs is applied as ONE single-pass regex substitution, never a sequence of independent
    data.replace() calls: two different secrets occasionally share the exact same value (most often the
    manifest default "admin"), which would otherwise mean several (old, new) pairs with an IDENTICAL
    `old`. Applying those one after another lets a LATER pair re-match text a PRIOR pair just wrote —
    every placeholder here is itself an English-ish `<secret-name>` string, so one placeholder's own
    text can contain a substring (like "admin") that a later pair is still looking for — producing
    nested garbage like `<secret-a-<secret-b-admin>-admin>`. A single combined pass never re-scans its
    own output, so this cannot happen; the first (old, new) pair for a given value wins if more than one
    secret shares it."""
    if literal_pairs:
        lookup = {}
        for old, new in literal_pairs:
            lookup.setdefault(old, new)
        combined = re.compile(b"|".join(re.escape(k) for k in sorted(lookup, key=len, reverse=True)))
        data = combined.sub(lambda m: lookup[m.group(0)], data)
    for pattern, placeholder, exempt in generic_rules:
        data = pattern.sub(lambda m, _exempt=exempt, _ph=placeholder: m.group(0) if m.group(0) in _exempt else _ph, data)
    return data

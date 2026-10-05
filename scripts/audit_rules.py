"""Generic rules for the public-readiness audit (epic 24 ticket #01): patterns that need no operator
data, safe to commit, shared by the full audit (scripts/public-readiness-audit.py, run through
scripts/deploy --script audit) and the generic-only subset wired into the standard lint run
(tests/lint.sh), which needs no key.

Every pattern here is assembled or escaped so that this file's own text never matches its own rules.
"""
import re

# ---------------------------------------------------------------------------------------------
# Tailnet CGNAT-range host addresses (group_vars/all/main.yml: tailscale_subnet "100.64.0.0/10").
# A HOST address in the range is flagged; the range's own CIDR notation is a functional value (used
# verbatim in group_vars and ADRs) and must never be scrubbed or flagged.
# ---------------------------------------------------------------------------------------------
_OCTET = r"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
_CGNAT_SECOND_OCTET = r"(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])"
CGNAT_ADDRESS_RE = re.compile((r"\b100\." + _CGNAT_SECOND_OCTET + r"\." + _OCTET + r"\." + _OCTET + r"(?:/\d{1,2})?\b").encode())
CGNAT_FUNCTIONAL_CIDR = b"100.64.0.0/10"

# Tailscale's IPv6 ULA prefix (group_vars/all/main.yml: tailscale_subnet_v6 "fd7a:115c:a1e0::/48") — the
# IPv6 counterpart of the CGNAT rule above. The bare "::/48" range notation itself never matches this
# pattern (it has no trailing hex digit before the slash, unlike the IPv4 CIDR), so — unlike the CGNAT
# rule — this one needs no explicit functional-value exemption.
_TAILNET_ULA_PREFIX = b"fd7a:115c:a1e0:"
TAILNET_ULA_ADDRESS_RE = re.compile(rb"\b" + re.escape(_TAILNET_ULA_PREFIX) + rb"[0-9a-fA-F:]*[0-9a-fA-F](?:/\d{1,3})?\b")

# ---------------------------------------------------------------------------------------------
# git-crypt key file header (the dead wiki-backup key is still in this repo's own history — see
# docs/public-readiness-audit.md). git-crypt's key file format begins with this fixed magic.
# ---------------------------------------------------------------------------------------------
GIT_CRYPT_HEADER_RE = re.compile(re.escape(b"\x00GITCRYPTKEY"))

# ---------------------------------------------------------------------------------------------
# Credential shapes. Assembled from pieces so this file's own source does not match its own rules.
# ---------------------------------------------------------------------------------------------
_PRIVATE_KEY_HEADER_RE = re.compile(rb"-----BEGIN (?:[A-Z]+ )?PRIVATE " + b"KEY-----")
_AGE_SECRET_KEY_RE = re.compile(b"AGE-SECRET-" + rb"KEY-1[A-Z0-9]{50,}")
_GITHUB_TOKEN_RE = re.compile(rb"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{82}\b")
_TAILSCALE_AUTHKEY_RE = re.compile(rb"\btskey-(?:auth|client)-[A-Za-z0-9]+-[A-Za-z0-9]+\b")
_OPENROUTER_KEY_RE = re.compile(rb"\bsk-or-v1-[a-f0-9]{64}\b")
_AWS_ACCESS_KEY_RE = re.compile(rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")
_GOOGLE_API_KEY_RE = re.compile(rb"\bAIza[0-9A-Za-z_-]{35}\b")
_SLACK_TOKEN_RE = re.compile(rb"\bxox[baprs]-[0-9A-Za-z-]{10,}\b")
_STRIPE_KEY_RE = re.compile(rb"\b(?:sk|rk)_live_[0-9A-Za-z]{24,}\b")

CREDENTIAL_SHAPE_RULES = [
    ("credential-shape:github-token", _GITHUB_TOKEN_RE),
    ("credential-shape:tailscale-authkey", _TAILSCALE_AUTHKEY_RE),
    ("credential-shape:openrouter-key", _OPENROUTER_KEY_RE),
    ("credential-shape:aws-access-key", _AWS_ACCESS_KEY_RE),
    ("credential-shape:google-api-key", _GOOGLE_API_KEY_RE),
    ("credential-shape:slack-token", _SLACK_TOKEN_RE),
    ("credential-shape:stripe-key", _STRIPE_KEY_RE),
    ("private-key-header", _PRIVATE_KEY_HEADER_RE),
    ("age-secret-key", _AGE_SECRET_KEY_RE),
]

# Rules with a bespoke exemption (CGNAT's functional CIDR) are listed separately from the plain
# credential shapes so scan_content() knows which rule name needs the exemption check.
RANGE_RULES = [
    ("tailnet-cgnat-address", CGNAT_ADDRESS_RE),
    ("tailnet-ula-address", TAILNET_ULA_ADDRESS_RE),
]
HEADER_RULES = [
    ("git-crypt-key-header", GIT_CRYPT_HEADER_RE),
]

GENERIC_RULES = CREDENTIAL_SHAPE_RULES + RANGE_RULES + HEADER_RULES


def scan_content(content, needle_rule, generic_rules=GENERIC_RULES):
    """Every (rule_name, line_number) hit in one blob of bytes. `needle_rule` maps a literal byte
    needle to the rule name that owns it (built from the run-time denylist; empty when no key is
    available). Operates on raw bytes throughout: no text decoding, so a NUL byte or any other
    non-UTF-8 byte (the git-crypt key header) never causes a silent skip or a decode error.

    Matches against the WHOLE buffer, never a line at a time: a needle (or a credential-shaped match)
    that itself contains a literal newline — a multi-line secret pasted verbatim — would otherwise be
    split across two lines before matching ever runs and could never be found in its literal form.
    The line number is recovered from the match's byte offset after the fact."""
    findings = []
    for needle, rule in needle_rule.items():
        if not needle:
            continue
        start = 0
        while True:
            pos = content.find(needle, start)
            if pos == -1:
                break
            findings.append((rule, content.count(b"\n", 0, pos) + 1))
            start = pos + 1   # overlapping occurrences of the same needle both count
    for rule_name, pattern in generic_rules:
        for m in pattern.finditer(content):
            if rule_name == "tailnet-cgnat-address" and m.group(0) == CGNAT_FUNCTIONAL_CIDR:
                continue
            findings.append((rule_name, content.count(b"\n", 0, m.start()) + 1))
    return findings

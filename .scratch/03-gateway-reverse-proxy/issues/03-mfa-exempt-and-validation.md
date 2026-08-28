# 03: Explicit MFA-exempt + fail-fast validation in the adapter

**What to build:** The MFA contract is made explicit and safe at the gateway layer. A route declared `mfa: false` is rendered without the `mfa_auth` snippet and that exemption is visible in the data (not implied by omission) — covering `auth.` itself and any future ACME/challenge route. The adapter also validates each route at render time: a route missing `upstream`, or with a non-boolean `mfa`, fails fast with a clear message so a typo cannot produce a silent 502 at deploy time.

**Blocked by:** #01 (Gateway module — route-data interface + Caddyfile adapter)

**Status:** ready-for-agent

- [ ] `mfa: false` routes render with no `mfa_auth` import; every other route wraps in `mfa_auth`.
- [ ] A route missing `upstream` fails the play at render time with a clear message.
- [ ] A route whose `mfa` is not a boolean fails the play at render time with a clear message.
- [ ] The three current routes still render byte-equivalent to today's Caddyfile (exemptions declared explicitly, not by accident).


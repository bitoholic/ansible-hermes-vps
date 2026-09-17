# 02: Migrate matrix and owntracks to port 8443 with DNS-01 issuance

**What to build:** The matrix and OwnTracks-recorder routes move off their shared port (which Cloudflare's proxy can't forward) onto a port it can, and their certificate issuance switches to a method that works even when Cloudflare is proxying the traffic — verified end-to-end before the DNS record's proxy status is ever touched.

**Blocked by:** #01
**Blocks:** #03

**Status:** ready-for-agent

- [ ] Both routes' shared listener moves to the new port; every other field on both route entries (auth model, TLS mode) is unchanged
- [ ] Certificate issuance for exactly these two routes switches to the DNS-01 method, authenticated via a newly-added, minimally-scoped API credential — every other route's certificate handling (self-signed internal CA) is untouched
- [ ] A real, trusted certificate is obtained and verified serving correctly for both hosts on the new port while their DNS records are still in their current (non-proxied) state
- [ ] The new credential is stored via this repo's existing secrets-manifest pattern, not hardcoded or logged
- [ ] Matrix and OwnTracks clients configured with the new port successfully connect

## Notes

See epic 19 spec, "Solution" and "Implementation Decisions". The actual Cloudflare-dashboard flip to a proxied DNS record is an explicit manual operator step performed only after this ticket's verification passes — it is not part of this ticket and is not Ansible-automatable (this repo has no DNS-record-management automation today). Do not flip the DNS record as part of implementing or testing this ticket.

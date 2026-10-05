# 02: Scrub the working tree to placeholders

**What to build:** Nothing in the current tree identifies the operator or their infrastructure: documentation, specs, ADRs, tickets and test fixtures use fixed placeholders, the documents stay readable and keep their reasoning, the functional tailnet-range constant and the text that legitimately describes it are left alone, and the audit's tree scan is clean.

**Blocked by:** #01, Epic 22 #06 (domain de-hardcoded from code), Epic 22 #09 (the real store exists to derive the denylist from)
**Blocks:** #03, #04

**Status:** done

- [x] Identifying values in documentation, specs, ADRs, tickets and test fixtures are replaced with fixed placeholders for the domain, hostnames, addresses, tailnet host addresses and personal names
- [x] The documents remain readable and preserve their reasoning; live-verification notes in tickets are kept, with real addresses and hostnames replaced
- [x] **The functional tailnet range constant** (a shared variable that drives firewall rules and Caddy matchers) **and the documents that describe the range are not altered** — a blind replacement that changes a functional value is a failure, shown by the existing gateway and firewall render tests still passing
- [x] The obsolete ignore entry for the dead git-crypt key file is removed or generalized so its identifying name is not left in the tree
- [x] The audit's tree scan, run through the wrapper against the real store, is clean, with no allowlist entry that lacks a written reason
- [x] All existing tests pass with their fixtures updated
- [x] The full-history scan is run and its counts reported in this ticket's notes for the record; history is left untouched (it stays as it is in this private repository, by design)

## Notes

See epic 24 spec, "Implementation Decisions" (scrub the working tree). Documentation that has merely drifted from later decisions is out of scope here.

**Process:** ran the real audit (`scripts/deploy --script audit`, against the real encrypted store — this
ticket is exactly what that access is for) to find every tree-scope identifying value, fixed them, then
re-ran until the tree scan was clean.

**What was scrubbed (placeholders, not values, recorded here):**
- The real domain and every subdomain built from it, across 8 tracked files (4 `.scratch` tickets/specs,
  `docs/adr/0005-tailnet-proxy-protocol-relay.md`) → `<domain>` (so `monitor.<domain>`, `wiki.<domain>`,
  `auth.<domain>`, etc. read naturally). One Tailscale-MagicDNS-mangled form (dots become dashes) got its
  own sentence-level rewrite rather than a token swap, since the mangling isn't reversible by a literal
  substitution.
- Three real tailnet host addresses (the VPS's own IPv4 and IPv6 tailnet addresses, and one peer device's
  IPv4 address, found in live-debugging narrative across 4 files) → `<vps-tailnet-ip>`,
  `<vps-tailnet-ipv6>`, `<tailnet-ip>` respectively. The IPv6 one was **not caught by the audit at all**
  — found by manual inspection while fixing the IPv4 occurrences on the same lines. Recorded for ticket
  #03: the generic rules have no IPv6-tailnet-ULA equivalent of the IPv4 CGNAT-range rule yet
  (Tailscale's ULA prefix, `fd7a:115c:a1e0::/48`, is as safe to hardcode as `100.64.0.0/10` already is).
- `.gitignore`'s obsolete entry for the dead git-crypt key file (its own filename embedded the real
  domain) → generalized to `*-git-crypt.key`, matching the dynamic `{{ inventory_hostname
  }}-git-crypt.key` naming `roles/backup/tasks/main.yml` already uses when fetching a fresh one.
- No personal name needed scrubbing: a direct search for the operator's git-config name found it nowhere
  in the tracked tree (it's only in commit *metadata*, which is explicitly out of scope — history stays
  as it is).

**Unplanned discovery, flagged here for the record (no value printed, consistent with the audit's own
discipline):** `tests/test_exit_nodes_render.yml`'s WireGuard-address fixture value for
`exit_node_windscribe_address` turned out, on re-running the audit, to be **exactly** the real, currently-
deployed `WINDSCRIBE_ADDRESS` secret — confirmed by changing the fixture to a different address and
seeing the `secret:WINDSCRIBE_ADDRESS` finding disappear from the tree. Fixed by picking an arbitrary,
unrelated CGNAT-range address for the fixture instead (it only needs to be *some* syntactically valid
address; the test never asserted anything about which one). This value is still in history permanently,
same as every other scrubbed value, by this epic's own design — rotating the real secret, if the operator
wants to, is their call and outside this ticket's scope.

**Allowlist (`audit-allowlist.yml`), added for genuinely non-identifying matches, each with a written
reason** (see that file): the stock default username `"admin"` (`ADGUARD_ADMIN_USERNAME`/`ADMIN_USERNAME`
— a common word, scoped to the whole tree since it recurs everywhere that word is used); Tailscale's own
universal quad-100 DNS stub address; and the test/fixture tailnet addresses already used as functional
render-test inputs (changing them would risk breaking a test for no reduction in real exposure) — each
scoped to the one file it appears in.

**Full-history scan, counts for the record (history is untouched, by design):**
- 2246 history-blob findings, 1391 commit-metadata findings (3637 total) remain across the repository's
  full history on every ref. These are now **exclusively** history/commit-metadata — the working tree's
  own scan (above) is fully clean.
- Before this ticket's allowlist and scrub, the tree scan alone reported 345 findings (286+3 of them the
  "admin" word-collision noise above; the rest the identifying values and fixture addresses fixed here).

**Tests:** full `tests/lint.sh` run passes end to end (exit 0), including the gateway/firewall render
tests (proving the functional `tailscale_subnet` constant and its `/10` CIDR text were never touched)
and the exit-node render test with its updated fixture address.

**Independent review (two parallel fresh-context agents — Standards/Fowler-baseline, Spec-conformance),
both against the real secrets store:** no defects found; both independently re-ran the real audit and
confirmed a clean tree scan, confirmed the CIDR constant's own lines are byte-untouched by this diff,
re-ran `tests/lint.sh` end to end, and independently reproduced the WINDSCRIBE_ADDRESS fixture coincidence
in a scratch worktree at the parent commit (without ever viewing the secret itself). The spec reviewer's
history-count re-run (2276/1396 vs. this ticket's recorded 2246/1391) was traced to a later, unrelated
doc-only commit changing the count slightly between when the number was recorded and when they re-ran it
— not a regression or a rewrite (`git merge-base --is-ancestor` confirms a plain fast-forward).

One structural concern both reviewers raised, accepted as a known limit rather than fixed here: the
`audit-allowlist.yml` entries match on `(path, rule)` only, never on value, so the two `tree:*`-scoped
`ADGUARD_ADMIN_USERNAME`/`ADMIN_USERNAME` entries would silently keep suppressing findings if either
secret were ever rotated away from the generic word "admin". Documented directly in
`audit-allowlist.yml`'s own header as a re-check reminder tied to rotating either secret, since the
allowlist file is what the operator will actually be looking at when they do.

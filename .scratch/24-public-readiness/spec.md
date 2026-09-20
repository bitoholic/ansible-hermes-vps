# Spec: Public readiness — be able to publish a public version of the repository without leaking the operator

> Status: ready-for-agent
> Source: Epic 24 — the operator may want a public version of this repository (this private repository stays their working repository and keeps the encrypted secrets file). It holds their private domain, tailnet addresses, username and operational detail in documentation, and its history holds those plus an early-committed (now dead) git-crypt key. The operator treats the domain and logins as secrets.
> Related: epic 22 (**hard dependency** — the encrypted secrets file, the deploy wrapper and the domain de-hardcoding must land first; this epic's scanner consumes the decrypted secret set), `04-backup-sync-module` (origin of the wiki backup's git-crypt key), epic 20's ADR-0005 (contains live tailnet detail that must be scrubbed). Reserved ADR number: ADR-0009.
> Vocabulary: see `CONTEXT.md` — **public-readiness audit**, **deploy wrapper**, **output redaction**. Also: "identifying value" (anything that ties the repository to the operator or their infrastructure: domain, hostnames, IPs, usernames, emails, tailnet addresses).

## Problem Statement

Making a repository public is irreversible in practice: every commit ever made becomes permanently readable, and search engines and scrapers copy it within minutes. The operator wants the option to do this, but today there is no way to know whether it is safe, and no procedure for doing it safely.

What a 2026-09-20 scan of this repository found (counts only; nothing sensitive is recorded here):

- **No credential-shaped strings** in any commit (184 at the time of the scan), and no `.env` was ever committed. The credentials themselves are clean.
- **The operator's private domain** appears in plaintext in 8 tracked files (specs, an ADR, a test fixture, one template — the template handled by epic 22) and in 10 commits of history. The operator counts it as a secret.
- **Tailnet addresses and the operator's username** appear in a few tracked files.
- **A real git-crypt key file** (the wiki backup's) was committed in the very first commit and removed nearly two months later; it is still in history on the main branch and on a feature branch. The operator regenerated the wiki's key after the discovery, so the leaked key is **dead** — but it is still a key file in a public history, and scanners will flag it.
- **Commit metadata.** Every commit already uses a GitHub no-reply address, so **no personal email is in history** — but the large majority (180 of 186 when checked) carry the operator's real full name as the author name, and the no-reply address itself embeds the account handle, which matches a label of the operator's domain.
- **Some exposure is not the repository's to fix.** Certificate-transparency logs and DNS reveal every hostname that has ever received a public certificate, whatever the repository contains; scrubbing prose cannot hide those.
- Specs, ADRs and tickets under the issue-tracker directory carry live-verification detail (real hostnames, addresses, debugging output).

There is no repeatable check that would catch any of this, and — because the list of identifying values is itself sensitive — no way to write such a check that doesn't commit the very values it hunts for.

## Solution

A **public-readiness audit** that finds identifying values without listing them anywhere in the repository: it derives its denylist at run time from the decrypted secret set (via epic 22's deploy wrapper), supplemented by an extra-terms entry in the same encrypted store and by generic patterns (credential shapes, tailnet-range addresses, key-file headers). It scans the working tree, the full history, and commit metadata, reports where (file and line, or commit) but never the value, and fails on any finding. The working tree is scrubbed to placeholders until the audit is clean, and a content policy keeps it that way. Publication is a **derived export**: the scrubbed tree, **minus the encrypted secrets file and the recipient configuration**, published to a separate public repository whose history consists only of export snapshots under a deliberately chosen commit identity (author name and email). **This repository stays private, stays the working repository, and keeps the encrypted store during and after migration and publication** — nothing about its history or visibility changes. A final, rehearsed go-live checklist ends at "ready to flip"; the flip itself remains the operator's manual decision. Generic guards keep the tree clean afterwards.

## User Stories

1. As the operator, I want a single command that tells me whether the repository is safe to publish, so that I never have to guess.
2. As the operator, I want the audit to find my private domain wherever it appears, including in history, so that I know the true extent of the exposure.
3. As the operator, I want the audit's list of things to look for to come from my encrypted secrets, so that no sensitive value is ever written into the repository to make the check possible.
4. As the operator, I want to add extra terms (hostnames, my name, emails) to the audit through the encrypted store, so that the check covers values that aren't credentials.
5. As the operator, I want the audit to also catch tailnet-range addresses and my VPS's own address, so that infrastructure detail can't slip through.
6. As the operator, I want the audit to recognize credential-shaped strings (tokens, private-key headers, age secret keys), so that a real secret is caught even if it isn't one I listed.
7. As the operator, I want the audit to recognize a git-crypt key file anywhere in history by its header, so that the dead key is found and flagged rather than assumed gone.
8. As the operator, I want the audit to scan commit messages and author and committer metadata, so that my real name and identifying handles in history are found.
9. As the operator, I want findings reported by file and line, or by commit, and rule name — never the matched value — so that the report itself is safe to read and share.
10. As the operator, I want the audit to run under the same output redaction as deployments, so that even a bug in its reporting can't print a value.
11. As the operator, I want a small, reasoned allowlist for legitimate matches (such as the encrypted file itself), so that the audit can reach a clean pass without being watered down.
12. As the operator, I want the audit to exit non-zero on any finding, so that it can gate the publication decision.
13. As the operator, I want the audit itself tested against a fixture repository with planted canaries in the tree, in history, in commit metadata and in encoded forms, so that I trust it to find real ones.
14. As the operator, I want my documentation, specs, ADRs, tickets and test fixtures scrubbed to placeholders (`<domain>`, `<vps-public-ip>`, `<tailnet-ip>`, and so on), so that the working tree carries nothing that identifies me.
15. As the operator, I want the scrub to keep the documents readable and useful, so that a public reader can still follow the reasoning.
16. As the operator, I want the old ignore entry for the dead key file removed or generalized, so that the file's identifying name isn't left in the tree.
17. As the operator, I want the live-verification notes in tickets kept but scrubbed of real addresses and hostnames, so that the project's history of decisions survives publication.
18. As the operator, I want cheap generic guards in the normal lint run for tailnet-range addresses and credential shapes, so that the tree stays clean after this epic without needing my key.
19. As the operator, I want a written content policy — placeholders only in committed prose — so that future documents don't reintroduce identifying values.
20. As the operator, I want the publication approach decided and recorded, including why an in-place history rewrite was rejected, so that I understand and can revisit the trade-off.
21. As the operator, I want publication done by exporting the scrubbed tree into a separate repository whose history contains only export snapshots, so that no old commit, pull-request reference or cache from this repository can expose the old data.
22. As the operator, I want the new repository's commits to carry an identity I choose deliberately — an author name as well as an email — instead of my real name, so that publishing doesn't publish my name.
23. As the operator, I want this private repository to stay my working repository and the home of the encrypted secrets file, with its history and visibility unchanged, so that publishing an export can't disturb the way I work or expose the store.
24. As the operator, I want it documented that development, tickets and the encrypted store stay in this private repository and that the public repository is export-only, so that my workstations and agent tooling need no repointing beyond an optional extra remote for publishing.
25. As the operator, I want a dry run of the whole procedure into a scratch *private* repository first, with the audit run over that repository's history, so that I've rehearsed it before anything is public.
26. As the operator, I want a fresh-clone test — clone the export into an empty directory and run the audit — so that I know the result doesn't depend on my machine's state.
27. As the operator, I want GitHub's secret scanning and push protection enabled on the new repository, so that the platform backs up my own checks.
28. As the operator, I want the export verified to contain neither the encrypted secrets file nor the recipient configuration, so that the public repository carries no ciphertext and no recipient keys.
29. As the operator, I want a short written threat model of what a public repository reveals even when clean (the stack's composition, versions and architecture), and of what stays exposed in the private repository that keeps the encrypted store (ciphertext and recipient public keys, so a private-repository leak still matters), so that publishing is an informed decision.
30. As the operator, I want a go-live checklist that ends with me flipping visibility by hand, so that this epic can never publish the repository by itself.
31. As the operator, I want a post-flip check that fetches the public repository unauthenticated and re-runs the audit, so that I confirm what the world sees.
32. As a future maintainer, I want the audit to be cheap to re-run before any later publication or release, so that it stays a habit.
33. As a future maintainer, I want the audit's rules documented (what is scanned, what is allowlisted and why), so that its guarantees are clear.
34. As the operator, I want it decided and recorded that the encrypted secrets file and recipient configuration are never part of the public export, so that I can't publish ciphertext of every credential by accident.
35. As the operator, I want the threat model to note that the no-reply address embeds my handle (which matches part of my domain) and that certificate-transparency logs and DNS expose hostnames regardless of the repository, so that I judge the real exposure, not just the repository's.
36. As the operator, I want the scrub and the lint guard to leave the functional tailnet range constant and the documents that legitimately describe it alone, so that fixing identifying values can't break a working variable.
37. As the operator, I want the audit to find a git-crypt key file in history even though it is a binary blob, so that the dead key is flagged by the audit itself rather than only by my knowing it exists.

## Implementation Decisions

- **The audit derives its denylist at run time.** It reads the decrypted secret set through epic 22's wrapper (script mode), plus an optional "extra terms" entry held in the same encrypted store (a declared extra under epic 22's name-set rule) (hostnames, names, emails — anything identifying that isn't a manifest credential), plus the resolved address of the target host. Nothing sensitive is committed to define the check. This is the design's central idea and the reason the epic depends on epic 22.
- **What it scans.** Every tracked file at the current commit; every blob in the full history (all refs), read **binary-safe** — the git-crypt key header is a binary blob that a text-only search silently skips; commit messages; author and committer names and emails. Matching covers each value literally and in its JSON-escaped and URL-encoded forms (the same forms epic 22's redaction handles), with the same minimum length.
- **Generic rules (no operator data, safe to commit).** Credential shapes (Tailscale, GitHub, OpenRouter-style API keys, private-key headers, age secret keys, common cloud key patterns); host addresses in the tailnet CGNAT range — deliberately **not** the range's own CIDR notation, which is a functional value in a shared variable and in ADRs and must not be scrubbed or flagged; the git-crypt key file header. The generic subset is also wired into the standard lint run (it needs no key).
- **Output and exit behavior.** Findings list file and line, or commit, plus the rule name; never the matched text. The audit runs under output redaction as a second guard, and exits non-zero on any finding. A minimal allowlist (path and rule, each with a written reason) covers legitimate matches such as the encrypted file's own contents.
- **Scrub the working tree.** Replace identifying values in documentation, specs, ADRs, tickets and test fixtures with fixed placeholders, preserving readability. Live-verification notes in tickets are kept, with real addresses and hostnames replaced. The obsolete ignore entry for the dead key file is removed or generalized. The functional tailnet range constant is left as it is, and the scrub is complete when the audit's tree scan is clean.
- **Publication strategy: a derived export to a separate public repository.** The scrubbed tree, excluding the encrypted secrets file and the SOPS recipient configuration, is exported to a **separate public repository**. Its history consists only of export snapshots (the first one a single initial commit; later exports add further snapshots), authored under a deliberately chosen identity — an author name as well as an email (the no-reply address alone is already the status quo and does not address the name). **This repository is unaffected:** it stays private, stays the working repository (development, tickets, the encrypted store), and its history — which still contains the dead key, the domain and the operator's real name — is never rewritten or published, which is fine while it is private. **Rejected: rewriting this repository's history in place and force-pushing** — it invalidates every workstation's clone; pull-request references and platform-side caches can outlive a force-push, so residue is hard to rule out; and one missed pattern is a permanent, public leak. **Rejected: flipping this repository's visibility as it stands** — that publishes every historical identifying value and the encrypted store. **Rejected: moving development to the new public repository** — it would split tickets, history and the store across two repositories for no benefit.
- **Decided: the encrypted store never goes public.** The encrypted secrets file and the recipient configuration stay in this private repository, during and after migration and publication; the public export excludes both and ships the names-only environment template instead. This was the operator's call, taking the review's point that publishing the store would publish ciphertext of every credential and identifying value permanently — a future leak of any recipient key would expose them all, and rotating credentials would not un-publish the identifying values. The audit (and the export fixture test) verify the exclusion.
- **Dry run, then fresh-clone verification.** The export procedure is rehearsed into a scratch private repository; the audit runs over its full history; a fresh clone of it in an empty directory is audited again. Only then is the real target created.
- **Platform settings at publication.** Secret scanning and push protection are enabled on the new repository; no workflows or hooks are added; the licence file is verified as intended.
- **Export exclusions.** The export procedure excludes the encrypted secrets file, the recipient configuration and any other secrets-tooling state by an explicit list, and the audit fails the export if either is present. Because the store stays private, no recipient review is needed for the public repository; the private repository's recipient list is maintained by epic 22's runbooks.
- **Threat-model note.** A short section in the ADR states what a clean public repository still reveals (the stack's composition, versions and architecture), that the no-reply address embeds the account handle, that certificate-transparency logs and DNS expose hostnames regardless of the repository, and why that is accepted. It also states what remains exposed in the *private* repository: ciphertext and recipient public keys, so its confidentiality (account security, access tokens, who is granted access) still matters.
- **Content policy.** A one-page rule — placeholders only in committed prose — linked from the agent-facing repository documentation so agents follow it too.
- **Go-live checklist.** Audit green on the export's tree and history; the export contains neither the encrypted store nor the recipient configuration; fresh-clone audit green; secret scanning on; threat-model note read; then the **operator flips visibility manually**; then an unauthenticated fetch of the public repository is audited. This epic ends at "ready to flip".
- **ADR.** A new ADR (ADR-0009) records the strategy, the recorded decision that the encrypted store stays private and out of the export, the chosen commit identity, the rejected alternatives, the threat model and the go-live checklist.

## Testing Decisions

- **What makes a good test here:** treat the audit as a black box over a fixture repository — plant a known set of identifying values and credential shapes and check that each is found and that nothing else is; never assert on how it searches.
- **Seams (existing seams preferred):**
  - **One new seam, at the highest level:** the audit run end to end against a fixture repository whose tree, history and commit metadata contain planted canaries (literal, JSON-escaped and URL-encoded) **and a binary blob carrying a git-crypt key header**, with a throwaway key and store generated at test time (the same technique as epic 22's wrapper test). Assertions: every canary found, including the binary header; the report contains no canary text; a clean fixture passes; the allowlist works and cannot silence an unlisted rule; exit status is correct.
  - The generic guard added to the standard lint run is a static check in the style of the existing placeholder guard in `tests/lint.sh` — it needs no key, is covered by the normal lint run, and has a negative case proving it does *not* flag the functional range constant.
- **Operator-validated:** the real audit over the real repository and export (it needs the operator's key), the dry run, the fresh-clone test, and the platform settings.
- **Prior art:** the placeholder guard in `tests/lint.sh`; epic 22's wrapper canary test; `tests/check-tailnet-caddy-access.sh`'s "what this cannot verify" framing.

## Out of Scope

- **Actually making the repository public.** This epic ends at ready-to-flip; the flip is the operator's manual decision.
- Rewriting this repository's history (it stays as it is, and keeps its role as the working repository and the home of the encrypted store).
- Publishing the wiki backup repository, or anything about its content or key.
- Proactively rotating credentials (nothing credential-shaped was found in history). If the audit ever does find a live credential, rotating it is the operator's call and outside this epic's tickets.
- Organisation-level GitHub settings, a security policy, supply-chain hardening, dependency automation.
- Licence changes.
- Correcting documentation that has drifted from later decisions (for example a glossary line describing Matrix traffic as private-only) — recorded for separate triage, not part of the scrub.

## Further Notes

- **The dead key.** The wiki backup's git-crypt key was regenerated after its discovery, so the copy in this repository's history unlocks nothing that matters today. It is still flagged by the audit's header rule, and the fresh-history approach removes it from the public repository without any rewrite.
- **Why counts only.** This spec records how many files and commits are affected, never which values — the same discipline the audit enforces.
- **Ordering.** Cannot start until epic 22's wrapper, encrypted store and domain de-hardcoding are in place. Independent of epics 21 and 23.
- **Reversibility.** Nothing here is hard to undo until the operator flips visibility; that is why the flip is left to them and preceded by a rehearsal.

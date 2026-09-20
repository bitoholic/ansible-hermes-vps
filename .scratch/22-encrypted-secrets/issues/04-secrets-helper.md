# 04: Secrets helper — maintain the encrypted store without ever writing plaintext

**What to build:** A companion command for everyday secret maintenance that replaces the interactive environment-prompting script: edit the store with values decrypted only in memory, see what is missing or extra under the name-set rule, fill in missing values with hidden input, manage recipients, rotate the data key, initialise a new workstation's key, and import an existing plaintext environment file with a verified round trip.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] Editing the store opens the decrypted values in the operator's editor with plaintext held only in memory and re-encrypts on save
- [ ] A check reports names missing (required) or undeclared, per the name-set rule, by name only
- [ ] A guided fill prompts for missing required values with hidden input, echoes nothing, and writes no plaintext file
- [ ] Recipients can be added and removed, and the data key rotated
- [ ] A new workstation's key can be initialised with safe permissions, printing only its public key
- [ ] An existing plaintext environment file can be imported — including the case where optional manifest entries are absent from it and where it holds declared extras — and the helper verifies that the decrypted names and values equal the source by digest without printing anything
- [ ] The names-only environment template is still generated from the manifest and its sync check passes; **the generator, whose own check refers to the prompt script being removed, is updated** so nothing refers to a script that no longer exists; the old prompt script is removed or reduced to a pointer to this helper
- [ ] Everything is tested against a fixture store and throwaway keys

## Notes

See epic 22 spec, "Implementation Decisions" (secrets helper; name-set rule; migration).

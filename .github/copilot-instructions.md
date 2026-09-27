This is a repository with Ansible code to configure and security-harden a single Linux Ubuntu VPS box for the purpose of hosting a hermes AI agent.
This repository MUST NOT contain any *plaintext* secret. Encrypted secrets are expected and belong in the
SOPS + age store (`secrets/secrets.enc.env`, committed) — that is the deliberate design (see
`docs/adr/0007-sops-age-encrypted-secrets.md`), not an exception to this rule. Never write a real
credential to any other tracked file, and never decrypt one to a file on disk; use `scripts/deploy`
(runs Ansible with the store decrypted into the child process's environment only) and `scripts/secrets`
(store maintenance) for everything that needs a secret's value.
Look for language based detailed instructions in .github/instructions folder.

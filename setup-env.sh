#!/usr/bin/env bash
# This interactive prompt script has been replaced by the secrets helper (epic 22 ticket #04), which maintains
# the encrypted secrets store instead of a local plaintext .env. Use:
#
#   scripts/secrets init-key         create your workstation's age key (first time only)
#   scripts/secrets fill             guided hidden-input fill of any missing required secrets
#   scripts/secrets edit             edit the store in your editor
#   scripts/secrets check            see what's missing or undeclared
#
# See README.md's secrets section and docs/adr/0007-*.md for the full workflow.
set -euo pipefail
echo "setup-env.sh has been replaced by the secrets helper. Run: scripts/secrets fill   (or: scripts/secrets --help)" >&2
exit 1

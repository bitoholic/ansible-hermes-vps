#!/usr/bin/env bash
# Shared bash test helpers for asserting on structured (YAML-shaped) text files
# by grep/awk rather than a real parser — this repo's test scripts are plain
# bash, not Python, so there's no yaml library available to them.
#
# Extracted here after a third caller needed it (tests/check-cloudflare-proxied-ingress.sh,
# epic 19 ticket #03) — tests/check-second-wave-services.sh's own block_of comment already
# flagged "unify if a third caller ever needs this" when it split list_has into block_of/
# entry_has during epic 18 ticket #06's review. Before that split, tests/check-adguard-dns.sh
# had already independently hit and fixed the same underlying bug in its own entry_has: a
# fixed-line `grep -A<N>` window ("list_has") could silently pass a real regression, because
# the window bled past the intended key's block into the next YAML entry (empirically found:
# flipping a required "- 53" list value still passed, since the window's tail matched a
# different, unrelated list's own "- 53" line right after it). The fix in both places was the
# same: bound the match to the block starting at key_pattern, up to (not including) the next
# line at the SAME indentation level — indentation is derived from key_pattern's own leading
# spaces, so this works for both group_vars/all/main.yml's 0-indent top-level keys and
# group_vars/all/secrets.yml's 2-indent manifest entries.
#
# Lives in tests/support/, not tests/lib/ — this repo's .gitignore has a
# generic Python-packaging `lib/` rule that would silently untrack anything
# placed there.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/support/yaml_block_assertions.sh"

# check_in <file> <pattern> <description> — whole-file, case-insensitive substring/regex
# match. Case-insensitive since some callers match README prose headings/phrases where
# capitalization isn't the thing under test.
check_in() { grep -qEi "$2" "$1" || { echo "FAIL: $1 missing: $3"; exit 1; }; }

# block_of <file> <key_pattern> — prints the bounded block starting at the line matching
# key_pattern, up to (not including) the next line at the same indentation level.
block_of() {
  local key_pat="$2"
  local indent="${key_pat#^}"; indent="${indent%%[^ ]*}"
  awk -v key_pat="$key_pat" -v exit_pat="^${indent}[A-Za-z_]" '
    $0 ~ key_pat { found=1; print; next }
    found && $0 ~ exit_pat { exit }
    found { print }
  ' "$1"
}

# entry_has <file> <key_pattern> <content_pattern> <description> — does
# block_of(file, key_pattern) contain content_pattern.
entry_has() { block_of "$1" "$2" | grep -qE "$3" || { echo "FAIL: $1 missing: $4"; exit 1; }; }

# entry_lacks <file> <key_pattern> <content_pattern> <description> — the negative of
# entry_has: fails if block_of(file, key_pattern) DOES contain content_pattern.
entry_lacks() { if block_of "$1" "$2" | grep -qE "$3"; then echo "FAIL: $1: $4"; exit 1; fi; }

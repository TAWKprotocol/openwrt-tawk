#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Guard the IP boundary: fail if anything that looks like TAWK protocol source,
# a key, a certificate or a credential has landed in the repository.
#
# The point is that this repository should be publishable at any moment without a
# cleanup pass. Scrubbing git history afterwards is painful and unreliable, so the
# cheap move is to never let it in.
#
# usage:
#   ./scripts/check-no-tawk-ip.sh          # scan tracked + untracked files
#   ./scripts/check-no-tawk-ip.sh --staged # scan only what is staged (pre-commit)
#
# install as a pre-commit hook:
#   ln -s ../../scripts/check-no-tawk-ip.sh .git/hooks/pre-commit
#
set -uo pipefail
# Find the repo root via git rather than from $0. When invoked through the
# pre-commit symlink, $0 is .git/hooks/pre-commit, so dirname/.. lands in .git/
# and every check silently sees no files -- a guard that quietly does nothing.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "FATAL: not inside a git repository" >&2; exit 1; }
cd "$ROOT"

MODE="${1:-all}"
fail=0
FILES=()   # bash 3.2 compatible: no mapfile
note() { printf '  %-9s %s\n' "$1" "$2"; }

if [ "$MODE" = "--staged" ]; then
	while IFS= read -r l; do FILES+=("$l"); done \
		< <(git diff --cached --name-only --diff-filter=ACM)
else
	while IFS= read -r l; do FILES+=("$l"); done \
		< <(git ls-files 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
fi
[ "${#FILES[@]}" -gt 0 ] || { echo "nothing to check"; exit 0; }

echo "== checking ${#FILES[@]} files =="

# 1. Protocol source. Two tiers, because documentation may legitimately *discuss*
#    TAWK types while code may not *use* them.
#      STRICT  - unambiguously code, flagged anywhere including prose.
#      SYMBOLS - bare type names; flagged only outside documentation.
STRICT_RE='(^|[^[:alnum:]_])(use[[:space:]]+tawk|tawk_protocol::|tawk::)'
# Additional local patterns, one extended-regex per line, from an optional
# gitignored file. Keeping them out of the repository means the committed
# defaults stay generic while a working copy can check whatever it needs to.
SYMBOL_RE=''
if [ -f .guard-patterns ]; then
	SYMBOL_RE="$(grep -v '^[[:space:]]*#' .guard-patterns | grep -v '^[[:space:]]*$' | paste -sd'|' -)"
fi
for f in "${FILES[@]}"; do
	[ -f "$f" ] || continue
	case "$f" in scripts/check-no-tawk-ip.sh) continue;; esac          # self-match
	if grep -InqE "$STRICT_RE" "$f" 2>/dev/null; then
		note "PROTO" "$f"; fail=1; continue
	fi
	case "$f" in *.md) continue;; esac                                  # prose may name types
	[ -n "$SYMBOL_RE" ] || continue
	if grep -InqE "$SYMBOL_RE" "$f" 2>/dev/null; then
		note "PROTO" "$f (protocol symbol in non-doc file)"; fail=1
	fi
done

# 2. Rust that links the protocol crates.
for f in "${FILES[@]}"; do
	case "$f" in
		*/Cargo.toml|Cargo.toml)
			grep -Iq 'tawk' "$f" 2>/dev/null && { note "CARGO" "$f (references tawk crates)"; fail=1; } ;;
		*.rs) note "RUST" "$f (no Rust belongs in this repo)"; fail=1 ;;
	esac
done

# 3. Keys, certificates and credential material.
for f in "${FILES[@]}"; do
	case "$f" in
		*.pem|*.key|*.p12|*.pfx|*.jks|*.crt|*.cer|*.der|*id_rsa*|*id_ed25519*|*.hex)
			note "KEYMAT" "$f"; fail=1 ;;
		*tawk-image-credentials*|*tawk-image-manifest*|*.tawk-credentials.env|*tawk-provision.conf)
			note "SECRET" "$f"; fail=1 ;;
	esac
	[ -f "$f" ] || continue
	case "$f" in scripts/check-no-tawk-ip.sh) continue;; esac          # self-match
	if grep -Iqm1 -e '-----BEGIN .*PRIVATE KEY-----' -e '-----BEGIN CERTIFICATE-----' "$f" 2>/dev/null; then
		note "KEYMAT" "$f (embedded key/cert block)"; fail=1
	fi
done

# 4. The ephemeral staging area must never be committed with content in it.
if git ls-files --error-unmatch tawk-artifacts 2>/dev/null | grep -qv '\.gitkeep$'; then
	note "ARTIFACT" "tawk-artifacts/ has tracked content -- it must stay empty"; fail=1
fi

echo
if [ "$fail" = 0 ]; then
	echo "PASS -- no TAWK IP, key material or credentials found."
else
	echo "FAIL -- the above must not be committed here. See README.md 'The IP boundary'."
	echo "        If a match is a false positive (prose, a doc reference), exclude it"
	echo "        explicitly rather than loosening the pattern."
fi
exit "$fail"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Bring TAWK build artifacts in as a DELIBERATE, EPHEMERAL step.
#
# Nothing in this repository builds, links against or vendors TAWK. When an image
# needs a TAWK binary, it is copied into tawk-artifacts/ for the duration of the
# build and removed afterwards. tawk-artifacts/ is gitignored in full.
#
# Doing it this way, rather than adding a submodule or a path dependency, keeps the
# repository publishable at any moment with no cleanup pass -- and keeps the copy
# visible as an explicit action in the build log rather than an implicit dependency.
#
# usage:
#   ./scripts/fetch-tawk-artifacts.sh <path-to-tawk-protocol> [target-triple]
#   ./scripts/fetch-tawk-artifacts.sh --clean
#
# then, in an OpenWrt package or an image files/ tree, reference
# tawk-artifacts/<binary> -- never a path back into the protocol repository.
#
set -euo pipefail
# Find the repo root via git rather than from $0. When invoked through the
# pre-commit symlink, $0 is .git/hooks/pre-commit, so dirname/.. lands in .git/
# and every check silently sees no files -- a guard that quietly does nothing.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "FATAL: not inside a git repository" >&2; exit 1; }
cd "$ROOT"
DEST="tawk-artifacts"

if [ "${1:-}" = "--clean" ]; then
	find "$DEST" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
	echo "cleaned $DEST/"
	exit 0
fi

SRC="${1:-}"
TRIPLE="${2:-aarch64-unknown-linux-musl}"
[ -n "$SRC" ] && [ -d "$SRC" ] || {
	echo "usage: $0 <path-to-tawk-protocol> [target-triple]"
	echo "       $0 --clean"
	exit 2
}

mkdir -p "$DEST"
found=0
for cand in \
	"$SRC/target/$TRIPLE/release/tawkd" \
	"$SRC/target/$TRIPLE/release/tawk-node" \
	"$SRC/target/release/tawkd" \
	"$SRC/target/release/tawk-node"
do
	[ -f "$cand" ] || continue
	install -m 0755 "$cand" "$DEST/"
	echo "copied  $(basename "$cand")  <- $cand"
	found=1
done

[ "$found" = 1 ] || {
	echo "FATAL: no TAWK binary found under $SRC/target/ for $TRIPLE."
	echo "       Build it in the protocol repo first, e.g.:"
	echo "         cargo build --release --target $TRIPLE"
	exit 1
}

cat <<EOF

Artifacts staged in $DEST/ (gitignored).

  * Reference them as $DEST/<binary> -- never a path into the protocol repo.
  * Run '$0 --clean' when the build is done.
  * './scripts/check-no-tawk-ip.sh' will fail if any of this is ever staged.
EOF

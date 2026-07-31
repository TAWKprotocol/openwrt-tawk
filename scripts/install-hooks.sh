#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install the IP-boundary hooks. Git will not auto-install hooks from a clone,
# so every working copy needs this run once.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
mkdir -p .git/hooks

ln -sfn ../../scripts/check-no-tawk-ip.sh .git/hooks/pre-commit

# pre-push matters more than pre-commit: a file committed and later deleted is
# gone from the working tree but still in history, and push sends history.
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
# Scan the commits actually being pushed, not the working tree.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
z=0000000000000000000000000000000000000000
rc=0
while read -r _local_ref local_sha _remote_ref remote_sha; do
	[ "$local_sha" = "$z" ] && continue                 # branch deletion
	if [ "$remote_sha" = "$z" ]; then range="$local_sha"   # new branch: all history
	else range="$local_sha --not $remote_sha"; fi
	# shellcheck disable=SC2086
	"$ROOT/scripts/check-no-tawk-ip.sh" --rev $range || rc=1
done
[ "$rc" = 0 ] || echo "push aborted -- see above."
exit "$rc"
HOOK
chmod +x .git/hooks/pre-push
echo "installed:"; ls -l .git/hooks/pre-commit .git/hooks/pre-push | sed 's/^/  /'

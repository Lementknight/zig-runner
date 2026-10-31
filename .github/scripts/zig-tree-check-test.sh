#!/usr/bin/env bash
# Tests zig-tree-check.sh (install-zig.sh's tree check) on a small fake tree: CI's "Workflows" job
# runs this.
set -euo pipefail

check="$(cd "$(dirname "$0")" && pwd)/zig-tree-check.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tree="$work/zig" list="$work/zig.stat"
failures=0

# A fresh tree, its list removed, and its digest computed the way install-zig.sh pins it.
fresh() {
	rm -rf "$tree" "$list"
	mkdir -p "$tree/lib/std" "$tree/doc"
	printf 'zig binary\n' >"$tree/zig"
	printf 'pub fn main() void {}\n' >"$tree/lib/std/std.zig"
	printf 'with space\n' >"$tree/doc/a b.txt"
	seq 1 2000 >"$tree/lib/big"
	sum=$(cd "$tree" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-64)
	# Later writes must land in a later kernel clock tick than these, as they would a job later.
	sleep 0.1
}

# expect NAME STATUS PATTERN: the check exits STATUS and prints a line matching PATTERN.
expect() {
	local out status=0
	out=$("$check" "$tree" "$sum" "$list" 2>&1) || status=$?
	if [ "$status" = "$2" ] && grep -qE "$3" <<<"$out"; then
		echo "ok: $1"
	else
		echo "FAIL: $1 (exit $status, wanted $2 and /$3/): $out"
		failures=$((failures + 1))
	fi
}

fresh
expect "first check reads every file" 0 '^Zig tree: 4 files, all re-hashed$'
ok() {
	if "${@:2}"; then echo "ok: $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
ok "a passing check leaves the list" test -s "$list"
expect "second check re-hashes nothing" 0 '^Zig tree: 4 files, 0 re-hashed$'

touch "$tree/doc/a b.txt"
expect "a touched file is re-hashed, alone" 0 '^Zig tree: 4 files, 1 re-hashed$'

fresh
expect "list written" 0 'all re-hashed'
mtime=$(stat -c %y "$tree/zig")
printf 'zig bjnary\n' >"$tree/zig"
touch -d "$mtime" "$tree/zig"
expect "same size and mtime, new content: fails" 1 '^$'
ok "a failing check removes the list" test ! -e "$list"

fresh
expect "list written" 0 'all re-hashed'
rm "$tree/lib/std/std.zig"
expect "a deleted file fails" 1 '^$'

fresh
expect "list written" 0 'all re-hashed'
printf 'extra\n' >"$tree/lib/extra"
expect "an added file fails" 1 '^$'

fresh
expect "list written" 0 'all re-hashed'
sed -i '2s/\t[0-9a-f]*$/\tnot-a-hash/' "$list"
expect "a corrupted list means the full check, which passes" 0 'all re-hashed'
sed -i '2d' "$list"
expect "a list missing a line means the full check" 0 'all re-hashed'
sed -i '2s/\t[0-9a-f]*$/\t0000000000000000000000000000000000000000000000000000000000000000/' "$list"
expect "a wrong hash in the list means the full check, which passes" 0 'all re-hashed'
printf 'garbage' >"$list"
expect "a garbage list means the full check" 0 'all re-hashed'
expect "and is rewritten" 0 '0 re-hashed'

fresh
expect "list written" 0 'all re-hashed'
ZIG_TREE_FULL=1 expect "ZIG_TREE_FULL=1 reads every file" 0 'all re-hashed'

if [ "$failures" != 0 ]; then
	echo "$failures failures" >&2
	exit 1
fi
echo "zig-tree-check: all passed"

#!/usr/bin/env bash
# Checks an unpacked Zig tree against its pinned digest (install-zig.sh):
#
#   zig-tree-check.sh TREE TREE_SUM STAT_LIST
#
# exits 0 when the tree matches, 1 when it does not. The digest is install-zig.sh's
#
#   find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
#
# Re-reading all of the tree's files (19,500, 309 MB for 0.17.0) costs 9-10 s on a Pi's SD card
# with a cold page cache, so a check that passes leaves STAT_LIST beside the tree: one line per
# file, in digest order, of path, size, inode, mtime, ctime (ns) and the file's sha256. The next
# check stats the tree, re-hashes only the files whose size, inode, mtime or ctime changed, takes
# the other files' hashes from the list, and compares the digest of the result with TREE_SUM. A list
# that is missing, unreadable, or names other files than the tree has, or a fast digest that does
# not match, means the full check, which alone decides that a tree is wrong.
#
# What the list does protect against: any write to a file sets its ctime to the current time, and
# a step cannot set ctime back (touch -d sets mtime and atime only; ctime takes root and moving the
# system clock, CAP_SYS_TIME). So a file that was changed, replaced or touched after the list was
# written no longer matches its line and is re-hashed: a step that edits the tree, by mistake or
# on purpose, is caught as before, and so is a disk that changed files under the runner.
#
# What it does not protect against: the list sits in the tool cache, and a job that can write the
# tree can write the list too. A job that changes a file and then rewrites that file's line with
# the new size, inode, mtime and ctime but the old hash passes the fast check: the list is a cache
# of hashes, not a signature, and nothing here can tell it from one this script wrote. The full
# check resisted that (a later job re-read every byte); this one only resists jobs that tamper with
# the tree and not, deliberately, with the list. Delete the list, or set ZIG_TREE_FULL=1, to make
# a job re-read everything.
set -euo pipefail

tree=$1 want=$2 list=$3
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tree"

# The files' stat lines, in digest order (byte order of the path, the first field), from one walk
# of the tree. A name with a control character or a backslash would not fit on one line (sha256sum
# escapes such names), so a tree with one gets the full check and no list. Stats are taken before
# any hashing: a file written in between is either hashed new (and fails the digest) or has a
# ctime past its line (and is re-hashed by the next check).
find . -type f -printf '%p\t%s\t%i\t%T@\t%C@\n' -name '*[[:cntrl:]\\]*' -fprint "$tmp/plain" |
	LC_ALL=C sort -t "$(printf '\t')" -k1,1 >"$tmp/stats"
plain=$([ ! -s "$tmp/plain" ] || echo 1)

# Writes the list from $tmp/stats and $tmp/sums ("sha256  path" per file, the same order), whole.
save() {
	[ -z "$plain" ] || return 0
	{ cut -c1-64 "$tmp/sums" | paste "$tmp/stats" - >"$list.$$" && mv -f "$list.$$" "$list"; } 2>/dev/null || rm -f "$list.$$"
}

fast() {
	[ -z "$plain" ] && [ -z "${ZIG_TREE_FULL:-}" ] && [ -r "$list" ] || return 1
	# Each file's line: its stored hash when its stat line is unchanged, "-" (re-hash) when not.
	# Exits 2 when the list does not line up with the tree, line by line.
	awk -F'\t' -v rehash="$tmp/rehash" '
		FILENAME == ARGV[1] { now[FNR] = $0; path[FNR] = $1; n = FNR; next }
		NF != 6 || FNR > n || $1 != path[FNR] || length($6) != 64 || $6 !~ /^[0-9a-f]+$/ { bad = 1; exit }
		{
			if ($1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 == now[FNR]) print $6 "  " $1
			else { print "-"; print $1 > rehash }
			m = FNR
		}
		END { if (bad || m != n) exit 2 }
	' "$tmp/stats" "$list" >"$tmp/plan" 2>/dev/null || return 1
	: >>"$tmp/rehash"
	xargs -d '\n' -r sha256sum <"$tmp/rehash" >"$tmp/fresh" || return 1
	awk -v fresh="$tmp/fresh" '$0 == "-" { if ((getline $0 < fresh) <= 0) exit 1 } { print }' \
		"$tmp/plan" >"$tmp/sums" || return 1
	[ "$(sha256sum <"$tmp/sums" | cut -c1-64)" = "$want" ] || return 1
	echo "Zig tree: $(wc -l <"$tmp/stats") files, $(wc -l <"$tmp/rehash") re-hashed"
}

# The pinned digest's own command.
full() {
	find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum >"$tmp/sums" || return 1
	[ "$(sha256sum <"$tmp/sums" | cut -c1-64)" = "$want" ] || return 1
	echo "Zig tree: $(wc -l <"$tmp/sums") files, all re-hashed"
}

if fast || full; then
	save
else
	rm -f "$list"
	exit 1
fi

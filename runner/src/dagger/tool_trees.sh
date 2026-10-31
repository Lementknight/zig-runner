#!/usr/bin/env bash
# The runner's check of the tool cache's trees (`set_up.verifyToolTrees`), run in "Set up job"
# before any step, with the tool cache and a volume of lists that no step ever mounts:
#
#   tool_trees.sh TOOL_CACHE LISTS
#
# For each directory TOOL_CACHE/TOOL/VERSION/NAME (the layout actions/tool-cache gives what setup
# actions unpack, and install-zig.sh's zig/VERSION/zig-ARCH-linux-VERSION), prints
#
#   DIGEST TREE FILES REHASHED
#
# where DIGEST is the digest install-zig.sh pins, run inside the tree:
#
#   find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
#
# The runner hands steps each DIGEST and TREE (ZIG_RUNNER_TOOL_TREES), and a script that pins a
# tree's digest skips its own check of the tree when the two match.
#
# Re-reading every file of a tree (19,500 files, 309 MB for Zig 0.17.0) costs about 1 s on the
# laptop and 10-19 s on razorbill under load, so a check leaves in LISTS one line per file of the
# tree, in digest order: path, size, inode, mtime, ctime (ns) and sha256. The next check re-hashes
# only the files whose stat line changed and takes the others' hashes from the list. That is sound
# because:
#
# - The lists are in a volume only this exec mounts. A job that could write a list could make a
#   changed file pass, by recording its new stat line with its old hash; no step can reach it.
# - Any write to a file sets its ctime to the current time, and a step cannot set it back (touch -d
#   sets mtime and atime; ctime takes moving the clock, CAP_SYS_TIME). So a file changed, replaced
#   or touched since its line was written no longer matches the line, and is re-hashed.
# - A file can be written twice within one tick of the kernel's coarse clock, once before this
#   check hashed it and once after, and keep its ctime: git's "racy clean" entries. A file whose
#   ctime is within 2 s of the check's start gets "racy" for a ctime, which no stat matches, so
#   the next check re-hashes it.
#
# A list that is missing, unreadable or names other files than the tree has means every file is
# read. A tree with a name that does not fit on one line (a control character or a backslash,
# which sha256sum escapes) is always read whole and gets no list.
set -uo pipefail

cache=$1 lists=$2
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
tab=$(printf '\t')
# TOOL_TREES_RACY_S is for the tests, which would otherwise wait out the 2 s; no step can set it.
racy=$(awk -v now="$(date +%s.%N)" -v s="${TOOL_TREES_RACY_S:-2}" \
	'BEGIN { printf "%.9f", now - s }')

# verify TREE LIST: prints TREE's digest, its number of files and how many were re-hashed, and
# rewrites LIST. Prints nothing when the tree could not be read.
verify() (
	cd "$1" || exit 1
	list=$2
	# The files' stat lines, in digest order (byte order of the path, the first field), from one
	# walk, taken before any hashing: a file written after its stat has a ctime past its line.
	find . -type f -printf '%p\t%s\t%i\t%T@\t%C@\n' -name '*[[:cntrl:]\\]*' -fprint "$tmp/odd" |
		LC_ALL=C sort -t "$tab" -k1,1 >"$tmp/stats" || exit 1
	odd=$([ ! -s "$tmp/odd" ] || echo 1)
	: >"$tmp/rehash"
	if [ -n "$odd" ] || [ ! -r "$list" ] || ! fast "$list"; then
		find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum >"$tmp/sums" || exit 1
		cp "$tmp/stats" "$tmp/rehash"
	fi
	# Written to a name of its own and moved into place: jobs set up at the same time share the
	# volume, and their shells' PIDs can be the same, each in its own container.
	if [ -z "$odd" ] && mkdir -p "$(dirname "$list")" && part=$(mktemp "$list.XXXXXX"); then
		if ! awk -F'\t' -v OFS='\t' -v racy="$racy" '$5 + 0 >= racy + 0 { $5 = "racy" } { print }' \
			"$tmp/stats" | paste - <(cut -c1-64 "$tmp/sums") >"$part" || ! mv -f "$part" "$list"; then
			rm -f "$part"
		fi
	fi
	echo "$(sha256sum <"$tmp/sums" | cut -c1-64) $1 $(wc -l <"$tmp/stats") $(wc -l <"$tmp/rehash")"
)

# fast LIST: $tmp/sums ("sha256  path" per file, digest order) from LIST where a file's stat line
# is unchanged, re-hashing the rest. Fails when LIST does not line up with the tree.
fast() {
	awk -F'\t' -v rehash="$tmp/rehash" '
		FILENAME == ARGV[1] { now[FNR] = $0; path[FNR] = $1; n = FNR; next }
		NF != 6 || FNR > n || $1 != path[FNR] || length($6) != 64 || $6 !~ /^[0-9a-f]+$/ { bad = 1; exit }
		{
			if ($1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 == now[FNR]) print $6 "  " $1
			else { print "-"; print $1 > rehash }
			m = FNR
		}
		END { if (bad || m != n) exit 2 }
	' "$tmp/stats" "$1" >"$tmp/plan" 2>/dev/null || return 1
	xargs -d '\n' -r sha256sum <"$tmp/rehash" >"$tmp/fresh" || return 1
	awk -v fresh="$tmp/fresh" '$0 == "-" { if ((getline $0 < fresh) <= 0) exit 1 } { print }' \
		"$tmp/plan" >"$tmp/sums"
}

cd "$cache" 2>/dev/null || exit 0
# Real directories only (find does not follow symlinks), and none of the dot-named directories
# install-zig.sh unpacks into before moving a tree into place.
find . -mindepth 3 -maxdepth 3 -type d ! -path '*/.*' -printf '%P\n' | LC_ALL=C sort >"$tmp/trees"
while IFS= read -r t; do
	case $t in *[!A-Za-z0-9._+/-]*) continue ;; esac
	verify "$cache/$t" "$lists/$t.stat"
done <"$tmp/trees"

# The lists of trees that are gone.
if cd "$lists" 2>/dev/null; then
	find . -type f -name '*.stat' -printf '%P\n' | while IFS= read -r l; do
		[ -d "$cache/${l%.stat}" ] || rm -f "$l"
	done
fi
exit 0

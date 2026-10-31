#!/usr/bin/env bash
# Installs Zig for this job and puts it on the job's PATH. The download is checked against the
# checksum ziglang.org publishes (https://ziglang.org/download/index.json), pinned here, so a
# changed or replaced tarball fails the job instead of building the release. A new Zig version
# means new checksums from that index, the same version in runner/build.zig.zon, and a new
# RUNNER_ZIG_SEED for runners that seed Zig caches (deploy/runner.env.example).
#
# Zig is unpacked into RUNNER_TOOL_CACHE, which a self-hosted runner keeps between jobs, and the
# unpacked tree is checked against a digest of all its files, pinned here too: a tree that another
# job changed is unpacked afresh, never used. On a Raspberry Pi, unpacking costs 9-16 s in a job
# and writes 588 MB to its disk; the check costs 2-10 s, depending on how much of the tree the page
# cache still holds, and writes nothing. The tree's digest is
#
#   find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
#
# run inside the tree unpacked from the checked tarball. zig-tree-check.sh runs the check, and keeps a
# list of the files' stat lines and hashes beside the tree so a job re-reads only the files whose
# size, inode, mtime or ctime changed; what that list does and does not protect against is there.
set -euo pipefail

version=0.17.0
arch=$(uname -m)
case $arch in
x86_64)
	sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
	tree_sum=310d0a4a95f328f94a350c4339226a4796daee589472b23f2a816d18874efaed
	;;
aarch64)
	sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
	tree_sum=aff98cd78f2569e83921f68c455fbfa81218d24718f8c24698f0ec10de4e9db8
	;;
*)
	echo "no Zig $version checksum for $arch" >&2
	exit 1
	;;
esac

dir="zig-$arch-linux-$version"
cache="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}/zig/$version"
tarball="$cache/$dir.tar.xz"
tree="$cache/$dir"
verified() { echo "$sum  $tarball" | sha256sum --check --quiet --status; }
check() { "$(dirname "$0")/zig-tree-check.sh" "$1" "$tree_sum" "$2"; }

if [ ! -d "$tree" ] || ! check "$tree" "$tree.stat" 2>/dev/null; then
	if ! verified 2>/dev/null; then
		mkdir -p "$cache"
		curl -fsSL -o "$tarball.part" "https://ziglang.org/download/$version/$dir.tar.xz"
		mv "$tarball.part" "$tarball"
		if ! verified; then
			echo "Zig $version for $arch does not match its pinned checksum" >&2
			rm -f "$tarball"
			exit 1
		fi
	fi
	# Unpacked beside the tree and moved into place whole, so a job running at the same time never
	# sees half a tree.
	part=$(mktemp -d "$cache/.$dir.XXXXXX")
	tar -xJf "$tarball" -C "$part"
	if ! check "$part/$dir" "$part/stat"; then
		echo "Zig $version for $arch unpacked to files that do not match their pinned digest" >&2
		rm -rf "$part"
		exit 1
	fi
	rm -rf "$tree" "$tree.stat"
	if mv -T "$part/$dir" "$tree"; then
		mv -f "$part/stat" "$tree.stat" 2>/dev/null || :
	else
		check "$tree" "$tree.stat"
	fi
	rm -rf "$part"
fi

echo "$tree" >>"$GITHUB_PATH"

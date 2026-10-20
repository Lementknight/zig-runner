#!/usr/bin/env bash
# Installs Zig for this job and puts it on the job's PATH. The download is checked against the
# checksum ziglang.org publishes (https://ziglang.org/download/index.json), pinned here, so a
# changed or replaced tarball fails the job instead of building the release. A new Zig version
# means new checksums from that index, and the same version in runner/build.zig.zon.
#
# The tarball is kept in RUNNER_TOOL_CACHE, which a self-hosted runner keeps between jobs, and is
# checked again every time: a cache that another job changed is downloaded afresh, never used.
# It is unpacked into the job's own temporary directory, which needs no special permissions.
set -euo pipefail

version=0.17.0
arch=$(uname -m)
case $arch in
x86_64) sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
aarch64) sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
*)
	echo "no Zig $version checksum for $arch" >&2
	exit 1
	;;
esac

dir="zig-$arch-linux-$version"
cache="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}/zig/$version"
tarball="$cache/$dir.tar.xz"
verified() { echo "$sum  $tarball" | sha256sum --check --quiet --status; }

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

dest="${RUNNER_TEMP:-/tmp}"
tar -xJf "$tarball" -C "$dest"
echo "$dest/$dir" >>"$GITHUB_PATH"

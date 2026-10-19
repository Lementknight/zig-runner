#!/usr/bin/env bash
# Installs Zig under /opt and puts it on the job's PATH. The download is checked against the
# checksum ziglang.org publishes (https://ziglang.org/download/index.json), pinned here, so a
# changed or replaced tarball fails the job instead of building the release. A new Zig version
# means new checksums from that index, and the same version in runner/build.zig.zon.
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
tarball="${RUNNER_TEMP:-/tmp}/$dir.tar.xz"
curl -fsSL -o "$tarball" "https://ziglang.org/download/$version/$dir.tar.xz"
echo "$sum  $tarball" | sha256sum --check --quiet
tar -xJf "$tarball" -C /opt
echo "/opt/$dir" >>"$GITHUB_PATH"

#!/usr/bin/env bash
# Installs Lean for this job, for the proofs in proofs/, and puts it (with lake) on the job's PATH.
# The release tarball is checked against the checksum the Lean project publishes for it on GitHub,
# pinned here, so a changed or replaced tarball fails the job instead of checking the proofs. A new
# Lean version means new checksums from that release, and the same version in proofs/lean-toolchain.
# No elan: the version is the one pinned, never one a toolchain file names.
set -euo pipefail

version=4.34.1
case $(uname -m) in
x86_64)
	asset="lean-$version-linux"
	sum=47bf4bbd78f70c2e9670598ab7124d92b6efb7330ff33e5fbb4030f6fd72e4e4
	;;
aarch64)
	asset="lean-$version-linux_aarch64"
	sum=fdb974c2cdb4627e090d5d4007b913e09d13c4868720fb5594e22808b3de9e37
	;;
*)
	echo "no Lean $version checksum for $(uname -m)" >&2
	exit 1
	;;
esac

want=$(cat "$(dirname "$0")/../../proofs/lean-toolchain")
if [[ $want != "leanprover/lean4:v$version" ]]; then
	echo "proofs/lean-toolchain names $want, and this script installs Lean $version" >&2
	exit 1
fi

dir="${RUNNER_TEMP:-/tmp}/lean"
mkdir -p "$dir"
curl -fsSL -o "$dir/$asset.tar.zst" "https://github.com/leanprover/lean4/releases/download/v$version/$asset.tar.zst"
if ! echo "$sum  $dir/$asset.tar.zst" | sha256sum --check --quiet --status; then
	echo "Lean $version ($asset) does not match its pinned checksum" >&2
	exit 1
fi
tar --zstd -xf "$dir/$asset.tar.zst" -C "$dir"
rm "$dir/$asset.tar.zst"
echo "$dir/$asset/bin" >>"$GITHUB_PATH"

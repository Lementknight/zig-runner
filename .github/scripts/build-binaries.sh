#!/usr/bin/env bash
# The release's binaries, as `zig build -Doptimize=ReleaseSafe -Dstrip -Dtarget=... -Dversion=TAG`
# builds them, but with the compiler directly (zig-modules.sh): on GitHub's runners, whose cache is
# always empty, `zig build` first spends about 100 s compiling Zig's build system. Both targets
# build at once. The binaries get the release's names, with SHA256SUMS beside them.
#
#   build-binaries.sh <version> <out-dir>      e.g. build-binaries.sh v0.14.0 dist
set -euo pipefail
version=${1:?usage: build-binaries.sh VERSION OUT_DIR}
out=$(realpath -m "${2:?usage: build-binaries.sh VERSION OUT_DIR}")
cd "$(dirname "$0")/../../runner"
# shellcheck source=.github/scripts/zig-modules.sh
. ../.github/scripts/zig-modules.sh

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$out"
# The tag exactly, as `-Dversion` writes it.
printf '%s' "$version" >"$scratch/version"

pids=()
for arch in x86_64 aarch64; do
	zig_modules "$scratch" "$scratch/version" -OReleaseSafe -fstrip -target "$arch-linux-musl"
	zig build-exe "${modules[@]}" --name runner -femit-bin="$out/zig-runner-linux-$arch" &
	pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
(cd "$out" && sha256sum zig-runner-linux-x86_64 zig-runner-linux-aarch64 >SHA256SUMS)

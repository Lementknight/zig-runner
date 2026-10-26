#!/usr/bin/env bash
# What `zig build test` does, by calling the compiler directly: the runner's tests, and the runner
# itself compiled (as build.zig's test step does, since the tests never reach its main loop).
#
# For GitHub's hosted runners, whose caches always start empty: `zig build` first compiles Zig's own
# build system, about 100 s on one core with an empty cache (Zig 0.17; 0.14.1 took 12 s), before it
# builds anything. Directly, the tests took 14.5 s instead of 118.7 s on a laptop, and the hosted
# test jobs spent 81-116 s on that step. The project's own runners keep the cache in a volume and use
# `zig build test`, as developers do.
#
# The module graph here must match build.zig's: src/main.zig as the root; build_version, the
# checkout's `git describe` (the same command); and tls, the package build.zig.zon pins. The release
# checks build with `zig build` on every pull request, so a difference between the two fails one of
# them.
#
# The package comes from git, not `zig fetch`: in Zig 0.17 fetching runs in the build system too, and
# costs the same 100 s. build.zig.zon pins it by a GitHub archive URL that names the commit, and git
# checks the commit hash, so the pin stays in build.zig.zon alone.
set -euo pipefail
cd "$(dirname "$0")/../../runner"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git describe --tags --always --dirty --abbrev=8 >"$scratch/version"

url=$(sed -n 's|^ *\.url = "\(https://github\.com/.*/archive/[0-9a-f]\{40\}\.tar\.gz\)",$|\1|p' build.zig.zon)
[[ $(wc -l <<<"$url") == 1 && -n $url ]] || { echo "expected one GitHub archive URL in build.zig.zon" >&2; exit 1; }
rev=${url##*/}
git init -q "$scratch/tls"
git -C "$scratch/tls" fetch -q --depth 1 "${url%/archive/*}" "${rev%.tar.gz}"
git -C "$scratch/tls" checkout -q FETCH_HEAD

modules=(--dep build_version --dep tls -Mroot=src/main.zig -Mbuild_version="$scratch/version"
	-Mtls="$scratch/tls/src/root.zig")

zig build-exe "${modules[@]}" --name runner -femit-bin="$scratch/runner" &
exe=$!
zig test "${modules[@]}"
wait "$exe"

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
# The module graph here must match build.zig's: src/main.zig as the root, and build_version, the
# checkout's `git describe` (the same command). The release checks build with `zig build` on every
# pull request, so a difference between the two fails one of them.
set -euo pipefail
cd "$(dirname "$0")/../../runner"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git describe --tags --always --dirty --abbrev=8 >"$scratch/version"
modules=(--dep build_version -Mroot=src/main.zig -Mbuild_version="$scratch/version")

zig build-exe "${modules[@]}" --name runner -femit-bin="$scratch/runner" &
exe=$!
zig test "${modules[@]}"
wait "$exe"

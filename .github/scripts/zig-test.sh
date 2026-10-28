#!/usr/bin/env bash
# What `zig build test` does, by calling the compiler directly: the runner's tests, and the runner
# itself compiled (as build.zig's test step does, since the tests never reach its main loop).
#
# For GitHub's hosted runners, whose caches always start empty: `zig build` first compiles Zig's own
# build system, about 100 s on one core with an empty cache (Zig 0.17; 0.14.1 took 12 s), before it
# builds anything. Directly, the tests took 14.5 s instead of 118.7 s on a laptop, and the hosted
# test jobs spent 81-116 s on that step. The project's own runners keep the cache in a volume and use
# `zig build test`, as developers do. The module graph is zig-modules.sh's.
set -euo pipefail
cd "$(dirname "$0")/../../runner"

# shellcheck source=.github/scripts/zig-modules.sh
. ../.github/scripts/zig-modules.sh

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git describe --tags --always --dirty --abbrev=8 >"$scratch/version"

zig_modules "$scratch" "$scratch/version"
plain=("${modules[@]}")
# ZIG_TEST_SANITIZE_THREAD=1: the tests under ThreadSanitizer (build.zig's -Dsanitize-thread), which
# fails them on a data race they run into.
tests=("${plain[@]}")
if [[ ${ZIG_TEST_SANITIZE_THREAD:-} == 1 ]]; then
	zig_modules "$scratch" "$scratch/version" -fsanitize-thread
	tests=("${modules[@]}")
fi

# ZIG_TEST_WAIT_FOR_DB=1: between compiling the tests and running them, wait for the database
# ci-database.sh started, which comes up while they compile (CI's Database tests job).
run=()
if [[ ${ZIG_TEST_WAIT_FOR_DB:-} == 1 ]]; then
	# shellcheck disable=SC2016 # expanded by that bash, not this one
	run=(--test-cmd bash --test-cmd -c --test-cmd '"$0" wait && exec "$@"'
		--test-cmd "$(realpath ../.github/scripts/ci-database.sh)" --test-cmd-bin)
fi

zig build-exe "${plain[@]}" --name runner -femit-bin="$scratch/runner" &
exe=$!
zig test "${tests[@]}" "${run[@]}"
wait "$exe"

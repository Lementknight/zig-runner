# shellcheck shell=bash
# The runner's module graph as runner/build.zig makes it, for compiling with the compiler directly
# instead of `zig build`, whose first step on a machine with an empty cache is compiling Zig's own
# build system, about 100 s on one core (BENCHMARKS.md). Sourced by zig-test.sh (CI's tests) and
# build-binaries.sh (the release's binaries), from runner/.
#
# The graph must match build.zig's: src/main.zig as the root; build_version, a file holding the
# version; and tls, the package build.zig.zon pins. The release checks build the image with
# `zig build` on pull requests that touch the packaging, so a difference between the two fails there.
#
# The package comes from git, not `zig fetch`: in Zig 0.17 fetching runs in the build system too, and
# costs the same 100 s. build.zig.zon pins it by a GitHub archive URL that names the commit, and git
# checks the commit hash, so the pin stays in build.zig.zon alone.

# zig_modules SCRATCH VERSION_FILE [FLAG...]: fetches the tls package into SCRATCH/tls (once) and sets
# `modules` to the arguments that declare the graph, each module preceded by FLAG... (per-module
# flags such as -OReleaseSafe, -target or -fsanitize-thread, which the compiler takes before each
# module they apply to).
zig_modules() {
	local scratch=$1 version=$2
	shift 2
	local url rev
	if [[ ! -d $scratch/tls ]]; then
		url=$(sed -n 's|^ *\.url = "\(https://github\.com/.*/archive/[0-9a-f]\{40\}\.tar\.gz\)",$|\1|p' build.zig.zon)
		[[ $(wc -l <<<"$url") == 1 && -n $url ]] || { echo "expected one GitHub archive URL in build.zig.zon" >&2; return 1; }
		rev=${url##*/}
		git init -q "$scratch/tls"
		git -C "$scratch/tls" fetch -q --depth 1 "${url%/archive/*}" "${rev%.tar.gz}"
		git -C "$scratch/tls" checkout -q FETCH_HEAD
	fi
	# shellcheck disable=SC2034 # for the caller
	modules=("$@" --dep build_version --dep tls -Mroot=src/main.zig
		"$@" -Mbuild_version="$version" "$@" -Mtls="$scratch/tls/src/root.zig")
}

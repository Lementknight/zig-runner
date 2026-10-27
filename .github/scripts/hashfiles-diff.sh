#!/usr/bin/env bash
# Compares which files the runner's hashFiles() selects with which GitHub's selects, on a test tree
# of awkward paths and random pattern sets (runner/tools/hashfilesdiff, Go):
#
#   - GitHub's: actions/runner's hashFiles script on @actions/glob 0.7, in a node container
#     (runner/tools/hashfilesdiff/reference.mjs);
#   - the runner's: Dagger's glob, asked through Dagger's Go SDK exactly as the runner asks, and
#     runner/src/hashfiles.zig choosing among what it lists (runner/tools/hashfilescorpus.zig).
#
# Needs Go, Docker, and a Dagger engine at _EXPERIMENTAL_DAGGER_RUNNER_HOST (for the Compose
# deployment: docker-container://zig-runner-engine-1). Not run in CI.
#
#   hashfiles-diff.sh [cases] [seed]     defaults: 400, 1
set -euo pipefail
cd "$(dirname "$0")/../../runner"
: "${_EXPERIMENTAL_DAGGER_RUNNER_HOST:?set it to the Dagger engine, e.g. docker-container://zig-runner-engine-1}"

s=$(mktemp -d)
trap 'rm -rf "$s"' EXIT
zig build-exe --dep hashfiles -Mroot=tools/hashfilescorpus.zig -Mhashfiles=src/hashfiles.zig \
	--name hashfilescorpus -femit-bin="$s/hashfilescorpus" &
(cd tools/hashfilesdiff && go run . setup -out "$s" -n "${1:-400}" -seed "${2:-1}")
wait

mkdir "$s/node"
cp tools/hashfilesdiff/reference.mjs "$s/node/"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$s/node:/app" -v "$s/tree:/tree:ro" \
	-v "$s/cases.json:/cases.json:ro" -w /app node:22-alpine sh -c 'npm init -y >/dev/null && npm install --silent @actions/glob@0.7.0 &&
		node reference.mjs /cases.json /tree' >"$s/reference.jsonl"

"$s/hashfilescorpus" plan "$s/cases.json" /tree >"$s/plan.json"
(cd tools/hashfilesdiff && go run . glob -tree "$s/tree" -plan "$s/plan.json") >"$s/globs.json" 2>"$s/dagger.log"
"$s/hashfilescorpus" dirs "$s/cases.json" /tree "$s/globs.json" >"$s/dirs.json"
(cd tools/hashfilesdiff && go run . contents -tree "$s/tree" -plan "$s/dirs.json") >"$s/contents.json" 2>>"$s/dagger.log"
"$s/hashfilescorpus" check "$s/cases.json" /tree "$s/globs.json" "$s/contents.json" "$s/reference.jsonl"

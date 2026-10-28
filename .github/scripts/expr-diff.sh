#!/usr/bin/env bash
# Compares the runner's expression evaluator (runner/src/expr.zig) with Gitea's (gitea.dev/actionslib)
# on random expressions: runner/tools/exprdiff (Go) writes them with actionslib's answers, in the
# format of GitHub's own cases, and runner/tools/exprcorpus.zig runs them through expr.zig. Needs Go.
#
#   expr-diff.sh [count] [seed] [depth]     defaults: 20000, 1, 5
#
# Every disagreement is printed with both answers. actionslib is not GitHub: settle each one against
# GitHub's implementation (actions/languageservices, expressions/src), and where actionslib is the
# one that is wrong, steer the generator clear of it (see the comment in exprdiff/main.go). CI runs
# it weekly (compare.yml), not on pull requests: it is a search for cases GitHub's own
# (expr-conformance.sh) do not cover.
set -euo pipefail
cd "$(dirname "$0")/../../runner"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/cases"
zig build-exe -OReleaseSafe --dep expr -Mroot=tools/exprcorpus.zig -Mexpr=src/expr.zig \
	--name exprcorpus -femit-bin="$scratch/exprcorpus" &
(cd tools/exprdiff && go run . -n "${1:-20000}" -seed "${2:-1}" -depth "${3:-5}" \
	-out "$scratch/cases/generated.json")
wait
"$scratch/exprcorpus" "$scratch/cases"

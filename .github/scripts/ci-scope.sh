#!/usr/bin/env bash
# Whether a pull request or a merge group can change what CI's build and test jobs check: sets
# `run=true` or `run=false` in GITHUB_OUTPUT, and says why. The jobs still run, and report, either
# way: a required check that never reports holds the merge queue forever, which a workflow-level
# path filter would do. So the jobs run this first and skip their own steps on `run=false`.
#
# `run=false` only when every changed file is one listed below as unable to change the runner's
# build or tests (documentation, the proofs, the deployment files, the other workflows and the
# scripts this job does not run); anything else, a file nobody listed included, runs everything.
# So does anything that is not a pull request or a merge group (a push to main), and anything this
# cannot work out (no base commit, a failed fetch). The Workflows job checks the workflows, scripts
# and deployment scripts on every change; proofs.yml and release.yml check theirs.
#
# BASE is the commit the change is compared with: the pull request's base, or the merge group's.
# A pull request is tested merged into main, which may since have moved past its base: the diff
# then holds main's changes too, which only ever means running more.
set -euo pipefail
cd "$(dirname "$0")/../.."

out=${GITHUB_OUTPUT:-/dev/stdout}
decide() {
	echo "run=$1" >>"$out"
	echo "$2"
	exit 0
}

case ${GITHUB_EVENT_NAME:-} in
pull_request | merge_group) ;;
*) decide true "${GITHUB_EVENT_NAME:-no event}: everything runs" ;;
esac
[[ ${BASE:-} =~ ^[0-9a-f]{40}$ ]] || decide true "no base commit to compare with: everything runs"
git cat-file -e "$BASE^{commit}" 2>/dev/null ||
	git fetch -q --depth=1 --no-tags origin "$BASE" ||
	decide true "could not fetch the base commit $BASE: everything runs"
# --no-renames: a file moved out of runner/ counts as a change to runner/.
changed=$(git diff --name-only --no-renames "$BASE" HEAD) ||
	decide true "could not compare with $BASE: everything runs"

while IFS= read -r file; do
	[[ -n $file ]] || continue
	case $file in
	# What the build and the tests read (db/: the database tests' migrations), and what runs them.
	runner/* | db/*) decide true "$file changed: everything runs" ;;
	.github/workflows/ci.yml) decide true "$file changed: everything runs" ;;
	.github/scripts/ci-scope.sh | .github/scripts/ci-database.sh | .github/scripts/install-zig.sh | \
		.github/scripts/zig-test.sh | .github/scripts/zig-modules.sh | .github/scripts/expr-conformance.sh)
		decide true "$file changed: everything runs"
		;;
	# Cannot change the runner's build or tests.
	*.md | docs/* | .changes/* | .changie.yaml | proofs/* | deploy/* | LICENSE | renovate.json | \
		.trivyignore.yaml | .githooks/* | .github/CODEOWNERS | .github/workflows/* | .github/scripts/*) ;;
	*) decide true "$file changed: everything runs" ;;
	esac
done <<<"$changed"
decide false "nothing the build or the tests read changed since $BASE: skipped"

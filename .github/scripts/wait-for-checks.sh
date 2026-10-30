#!/usr/bin/env bash
# Waits until every check named in REQUIRED_CHECKS (one per line) has succeeded on a commit, for up
# to WAIT_MINUTES (default 40). A check that completed without success fails at once; one still
# queued or running at the end, or never started, fails then. Each is named, followed by what its
# failure means (the second argument). Only GitHub Actions' check runs count (another app could
# name one the same), from every page, and for each name the latest (the highest id): a re-run is a
# new check run under the same name. A failed request counts as none found yet, so a passing
# GitHub hiccup costs a poll. release.yml's deploy job waits so for the tagged commit, and
# version.yml's tag job for main's, before tagging it. Needs gh with GH_TOKEN, and
# GITHUB_REPOSITORY.
#
#   wait-for-checks.sh <commit> <consequence>
#   e.g. wait-for-checks.sh "$GITHUB_SHA" "v1.2.3 is not deployed (README, \"Deploying releases\")"
set -euo pipefail

sha=${1:?usage: wait-for-checks.sh COMMIT CONSEQUENCE}
consequence=${2:?usage: wait-for-checks.sh COMMIT CONSEQUENCE}
: "${REQUIRED_CHECKS:?REQUIRED_CHECKS must name the checks, one per line}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
wait_minutes=${WAIT_MINUTES:-40}

mapfile -t checks <<<"$REQUIRED_CHECKS"
deadline=$((SECONDS + wait_minutes * 60))
while :; do
	runs=$(gh api --paginate "repos/$GITHUB_REPOSITORY/commits/$sha/check-runs?per_page=100" \
		--jq '.check_runs[] | select(.app.slug == "github-actions") | {id, name, status, conclusion}' |
		jq -s .) || {
		echo "::warning::could not list the check runs on $sha"
		runs='[]'
	}
	waiting=()
	for name in "${checks[@]}"; do
		state=$(jq -r --arg name "$name" '[.[] | select(.name == $name)] | max_by(.id)
			// {status: "missing"} | if .status == "completed" then .conclusion else .status end' <<<"$runs")
		case $state in
		success) ;;
		missing | queued | in_progress | waiting | requested | pending) waiting+=("$name ($state)") ;;
		*)
			echo "::error::$name: $state on $sha, so $consequence"
			exit 1
			;;
		esac
	done
	((${#waiting[@]} > 0)) || break
	if ((SECONDS >= deadline)); then
		echo "::error::still waiting after $wait_minutes minutes for: ${waiting[*]}; $consequence"
		exit 1
	fi
	echo "waiting for: ${waiting[*]}"
	sleep 30
done
echo "passed on $sha: ${checks[*]}"

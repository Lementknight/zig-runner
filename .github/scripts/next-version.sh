#!/usr/bin/env bash
# Prints the next version tag (v1.2.3) for main as it stands, or nothing when no pull request has
# merged into main since the last release. The rules are in the README, under "Versioning": the
# largest bump among the pull requests merged since then wins. Why each pull request bumps what it
# does goes to stderr.
#
# Run from a clone with every tag and main's history (`fetch-depth: 0`), with `gh` logged in.
set -euo pipefail

base_branch=${BASE_BRANCH:-main}
head=$(git rev-parse -q --verify "origin/$base_branch" || git rev-parse HEAD)

last=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1)
if [[ -z $last ]]; then
	echo "no version tag to bump from: tag a first release (v0.1.0) by hand" >&2
	exit 1
fi
# A release's tag sits on a commit just off main, the one setting build.zig.zon's version; the
# main commit it was cut from is where the two meet. An older tag on main itself meets at itself.
since=$(git merge-base "$last" "$head")

# Each commit main gained since is a pull request's merge (or, rebased, one of its commits).
queue=()
for sha in $(git rev-list --first-parent "$since..$head"); do
	while read -r n; do
		[[ -n $n ]] && queue+=("$n")
	done < <(gh api "repos/{owner}/{repo}/commits/$sha/pulls" \
		--jq ".[] | select(.merged_at != null and .base.ref == \"$base_branch\") | .number")
done

bump=0 # 0 none, 1 patch, 2 minor, 3 major
names=(none patch minor major)
seen=" "
while ((${#queue[@]})); do
	n=${queue[0]}
	queue=("${queue[@]:1}")
	[[ $seen == *" $n "* ]] && continue
	seen+="$n "

	pr=$(gh pr view "$n" --json headRefName,labels)
	branch=$(jq -r .headRefName <<<"$pr")
	if jq -e 'any(.labels[]; .name == "breaking")' <<<"$pr" >/dev/null; then
		b=3
	else
		case $branch in
		bugfix/* | hotfix/* | ci/*) b=1 ;;
		*) b=2 ;;
		esac
	fi
	echo "#$n $branch: ${names[b]}" >&2
	((b > bump)) && bump=$b

	# A stack: the pull requests merged into this one's branch reached main with it.
	while read -r m; do
		[[ -n $m ]] && queue+=("$m")
	done < <(gh pr list --base "$branch" --state merged --limit 100 --json number --jq '.[].number')
done

IFS=. read -r major minor patch <<<"${last#v}"
case $bump in
3) echo "v$((major + 1)).0.0" ;;
2) echo "v$major.$((minor + 1)).0" ;;
1) echo "v$major.$minor.$((patch + 1))" ;;
*) echo "no pull request merged into $base_branch since $last" >&2 ;;
esac

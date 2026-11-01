#!/usr/bin/env bash
# Checks the default job image, named in runner/src/dagger.zig (default_image): the shared base
# every job's chain starts from, provisioned by set_up.zig. CI's "Workflows" job runs this on every
# pull request. The pin must be the shape Renovate's manager reads (renovate.json; the literal is
# split over two lines with ++), and a multi-arch index on Docker Hub covering both machines the
# runner deploys to (linux/amd64 and linux/arm64/v8), whose bytes hash to the pinned digest. So a
# Renovate ubuntu pull request, or a re-wrapped literal that would blind Renovate, fails here, not
# on a runner. Docker Hub's registry API is asked anonymously with curl, no Docker needed; the
# tag's current digest is printed too, which is how to pin by hand. A fetch that fails exits 75
# (EX_TEMPFAIL), which the CI step tries again.
set -euo pipefail
cd "$(dirname "$0")/../.."

source=runner/src/dagger.zig
# The constant's two lines joined, then the quotes, spaces and ++ dropped: ubuntu:<tag>@sha256:<hex>.
mapfile -t found < <(tr -d '\n' <"$source" |
	grep -oE '"ubuntu:[A-Za-z0-9._-]+" *\+\+ *"@sha256:[a-f0-9]{64}"' | tr -d '" +')
if ((${#found[@]} != 1)); then
	echo "ubuntu-pin: expected exactly one default_image in $source of the shape" \
		"\"ubuntu:<tag>\" ++ \"@sha256:<64 hex>\", as renovate.json reads it; found ${#found[@]}" >&2
	exit 1
fi
address=${found[0]}
tag=${address%@*}
tag=${tag#ubuntu:}
digest=${address#*@}
echo "ubuntu-pin: $address"

registry=https://registry-1.docker.io/v2/library/ubuntu
accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
token=$(curl -fsS --retry 2 \
	'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull' |
	jq -r .token) || {
	echo "ubuntu-pin: could not get an anonymous token from Docker Hub" >&2
	exit 75
}
# A file, not a variable: the bytes are hashed as served, trailing newline and all.
index=$(mktemp)
trap 'rm -f "$index"' EXIT
curl -fsS --retry 2 -o "$index" -H "Authorization: Bearer $token" -H "Accept: $accept" \
	"$registry/manifests/$digest" || {
	echo "ubuntu-pin: could not fetch $address from Docker Hub" >&2
	exit 75
}
# The registry is trusted for nothing: the bytes must be the pinned digest's.
if [[ "sha256:$(sha256sum <"$index" | cut -d' ' -f1)" != "$digest" ]]; then
	echo "ubuntu-pin: what Docker Hub returned for $address does not hash to its digest" >&2
	exit 1
fi
# The index itself: the engine picks its platform from it, so both deploy targets must be listed.
if ! jq -e '
	(.mediaType == "application/vnd.oci.image.index.v1+json"
	 or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json")
	and ([.manifests[].platform | select(. != null) | "\(.os)/\(.architecture)/\(.variant // "")"]
	     | (index("linux/amd64/") != null and index("linux/arm64/v8") != null))' \
	"$index" >/dev/null; then
	echo "ubuntu-pin: $address is not a multi-arch index listing linux/amd64 and linux/arm64/v8;" \
		"pin the index digest, the tag's Docker-Content-Digest below" >&2
	exit 1
fi

# Informational: a tag that moved on is Renovate's to propose, not a failure.
current=$(curl -fsS --retry 2 -o /dev/null -D - -H "Authorization: Bearer $token" \
	-H "Accept: $accept" "$registry/manifests/$tag" |
	tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }') || current=unknown
echo "ubuntu-pin: ubuntu:$tag is now ${current:-unknown}"
echo "ubuntu-pin: a multi-arch index for linux/amd64 and linux/arm64/v8"

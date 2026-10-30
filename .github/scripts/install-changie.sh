#!/usr/bin/env bash
# Installs changie, which batches the changelog at a release (version.yml), and puts it on the job's
# PATH. The download is checked against the checksum its release publishes (checksums.txt), pinned
# here, so a changed or replaced tarball fails the job instead of writing the release. CI's
# Workflows job runs this on every pull request, so a new version (Renovate's) fails there until
# its checksum is updated, not at the next release, after it was approved.
set -euo pipefail

version=1.26.0
# changie_<version>_linux_amd64.tar.gz in the release's checksums.txt.
sum=eab168c8287a6e91912e1c02e5260911232d945bfd3c89d8a0e1ace6bb7b6161

dir="${RUNNER_TEMP:-/tmp}/changie-$version"
tarball="$dir/changie.tar.gz"
mkdir -p "$dir"
curl -fsSL -o "$tarball" \
	"https://github.com/miniscruff/changie/releases/download/v$version/changie_${version}_linux_amd64.tar.gz"
if ! echo "$sum  $tarball" | sha256sum --check --quiet --status; then
	echo "changie $version does not match its pinned checksum: update it from the release's checksums.txt" >&2
	exit 1
fi
tar -xzf "$tarball" -C "$dir" changie
"$dir/changie" --version
echo "$dir" >>"${GITHUB_PATH:-/dev/null}"

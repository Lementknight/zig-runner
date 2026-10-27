#!/usr/bin/env bash
# Runs shellcheck over every shell script in the repository: CI's "Workflows" job and the pre-push hook
# run this. The scripts are found by their #! line, so a new one is checked without being listed.
# The checker itself runs from its image, pinned by digest, so every run uses the same version.
set -euo pipefail
cd "$(dirname "$0")/../.."

mapfile -t scripts < <(git ls-files -z | xargs -0 grep -lsE '^#!/usr/bin/env (bash|sh)|^#!/bin/(ba)?sh' -- 2>/dev/null; echo .githooks/common.sh)
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb -x "${scripts[@]}"
echo "shellcheck: ${#scripts[@]} scripts, no findings"

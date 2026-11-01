#!/usr/bin/env bash
# Checks that runner/src/native/testdata/step_keys.tsv is what the Lean model says it is: the
# output of `keyoracle` (proofs/KeyOracle.lean), which computes each vector from the model's keys
# (`Runner.Build.K`) and the native key's spelling (`Runner.Native.stepPreimage`), whose soundness
# `Runner.Native.native_key_iff` proves. runner/src/native/key_vectors.zig checks the Zig key
# against the same file, so the model and the code are compared through it. Needs Lean (lake).
#
#   key-vectors.sh            check, failing with the difference
#   key-vectors.sh --write    rewrite the file from the model
set -euo pipefail
cd "$(dirname "$0")/../.."

file=runner/src/native/testdata/step_keys.tsv
(cd proofs && lake build keyoracle >/dev/null)
if [[ ${1:-} == --write ]]; then
	proofs/.lake/build/bin/keyoracle >"$file"
	echo "wrote $file"
	exit 0
fi
s=$(mktemp -d)
trap 'rm -rf "$s"' EXIT
proofs/.lake/build/bin/keyoracle >"$s/step_keys.tsv"
if cmp -s "$file" "$s/step_keys.tsv"; then
	echo "$file is the model's ($(wc -l <"$file") vectors)"
	exit 0
fi
echo "$file is not the model's; rewrite it with .github/scripts/key-vectors.sh --write:"
diff "$file" "$s/step_keys.tsv" | cut -c1-200 || true
exit 1

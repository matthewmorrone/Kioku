#!/bin/sh
# Xcode Cloud post-clone hook. Runs immediately after `git clone` and before
# any build phase, with /usr/bin/sh as the interpreter (NOT bash — keep this
# script POSIX-portable). The path is fixed by Apple: `ci_scripts/ci_post_clone.sh`
# at the repo root, executable bit set, no arguments.
#
# It provisions the gitignored build resources the app bundles, by delegating to
# the very same ensure_* scripts GitHub Actions and scripts/setup.sh use — so all
# three CI/setup paths stay in lockstep instead of duplicating (and drifting from)
# the decompression logic:
#   - Resources/dictionary.sqlite     (reassembled from committed .zst.part-* chunks)
#   - Resources/handwriting-ja.model  (from committed handwriting-ja.model.zst)
# Both raw files are .gitignored; without this step the build fails with
# "The file '…' couldn't be opened because there is no such file" once Xcode tries
# to bundle Resources/.

set -eu

# Xcode Cloud sets CI_PRIMARY_REPOSITORY_PATH to the cloned repo root.
# Fall back to a relative resolution for the case where the script runs locally
# for testing (scripts/run-ci-post-clone-locally, etc).
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "→ ci_post_clone: REPO_ROOT=$REPO_ROOT"

# Xcode Cloud's macOS image ships with Homebrew preinstalled but not every CLI
# tool — install zstd on demand (cheap when already cached). The ensure scripts
# also check for zstd, but installing here keeps their failure path unreached.
if ! command -v zstd >/dev/null 2>&1; then
    echo "→ ci_post_clone: installing zstd via Homebrew"
    HOMEBREW_NO_AUTO_UPDATE=1 brew install zstd
fi

# The ensure_* scripts are bash (globs, [[ ]]); invoke them with bash explicitly
# since this hook itself runs under POSIX sh. Each resolves the repo root from its
# own location, so cwd doesn't matter.
bash "$REPO_ROOT/scripts/ensure_dictionary.sh"
bash "$REPO_ROOT/scripts/ensure_handwriting_model.sh"

echo "✓ ci_post_clone: build resources ready"

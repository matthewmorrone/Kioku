#!/bin/sh
# Xcode Cloud post-clone hook. Runs immediately after `git clone` and before
# any build phase, with /usr/bin/sh as the interpreter (NOT bash — keep this
# script POSIX-portable). The path is fixed by Apple: `ci_scripts/ci_post_clone.sh`
# at the repo root, executable bit set, no arguments.
#
# We use it for one thing: decompress `Resources/dictionary.sqlite.zst` into
# `Resources/dictionary.sqlite`. The raw SQLite is .gitignored (~233 MB; only
# the ~68 MB .zst is committed), so without this step the build fails with
# "The file 'dictionary.sqlite' couldn't be opened because there is no such
# file" once Xcode tries to bundle Resources/.
#
# Locally, scripts/setup.sh invokes scripts/ensure_dictionary.sh for the same
# effect; this file is just the Xcode-Cloud-specific re-entry point.

set -eu

# Xcode Cloud sets CI_PRIMARY_REPOSITORY_PATH to the cloned repo root.
# Fall back to a relative resolution for the case where the script runs locally
# for testing (scripts/run-ci-post-clone-locally, etc).
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "→ ci_post_clone: REPO_ROOT=$REPO_ROOT"

ARCHIVE="$REPO_ROOT/Resources/dictionary.sqlite.zst"
SQLITE="$REPO_ROOT/Resources/dictionary.sqlite"

if [ ! -f "$ARCHIVE" ]; then
    echo "✗ ci_post_clone: missing $ARCHIVE — repo state is incomplete." >&2
    exit 1
fi

# Xcode Cloud's macOS image ships with Homebrew preinstalled but not every
# CLI tool — install zstd on demand. Cheap when already cached.
if ! command -v zstd >/dev/null 2>&1; then
    echo "→ ci_post_clone: installing zstd via Homebrew"
    HOMEBREW_NO_AUTO_UPDATE=1 brew install zstd
fi

echo "→ ci_post_clone: decompressing dictionary.sqlite.zst → dictionary.sqlite"
zstd -d --force "$ARCHIVE" -o "$SQLITE"
ls -lh "$SQLITE"

echo "✓ ci_post_clone: dictionary ready"

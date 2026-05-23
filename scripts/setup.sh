#!/usr/bin/env bash
# One-shot setup for a fresh clone or worktree: wires the repo's git hooks and
# does a smoke run of the invariants validator. Idempotent — safe to re-run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 1. Point git at the repo-tracked hooks directory.
current="$(git config --get core.hooksPath || true)"
if [[ "$current" != ".githooks" ]]; then
  git config core.hooksPath .githooks
  echo "✓ Set core.hooksPath = .githooks"
else
  echo "✓ core.hooksPath already set to .githooks"
fi

# 2. Make sure the hooks are executable (some clones strip the bit).
chmod +x .githooks/pre-commit .githooks/pre-push \
         scripts/validate_invariants.sh scripts/hook_check_invariants.sh

# 3. Verify the validator runs cleanly against the current tree.
echo
echo "Running invariant checks..."
bash scripts/validate_invariants.sh

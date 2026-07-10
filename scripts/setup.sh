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

# 3. Decompress the committed dictionary + handwriting-model archives if the raw
#    files are missing.
echo
bash scripts/ensure_dictionary.sh
bash scripts/ensure_handwriting_model.sh

# 3b. Provision the Python venv the dictionary builder uses. The Xcode build phase runs
#     Resources/generate_db.py with ./.venv/bin/python3 when it exists, and generate_db.py
#     now HARD-FAILS without wordfreq (the only frequency source for kana-usually words like
#     その — see requirements.txt). Installing it here means a rebuild after editing a data
#     input can't silently ship the degraded, all-"Rare" frequency data.
echo
if [[ ! -x .venv/bin/python3 ]]; then
  echo "Creating .venv for dictionary generation..."
  python3 -m venv .venv
fi
.venv/bin/python3 -m pip install -q --upgrade pip
.venv/bin/python3 -m pip install -q -r requirements.txt
echo "✓ Dictionary build deps installed in .venv (wordfreq, mecab-python3, ipadic)"

# 4. Verify the validator runs cleanly against the current tree.
echo
echo "Running invariant checks..."
bash scripts/validate_invariants.sh

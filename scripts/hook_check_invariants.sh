#!/usr/bin/env bash
# PostToolUse hook for Claude Code: runs the invariants validator against any
# Swift file just touched by Write/Edit. Silent on success, prints findings on
# failure so the model sees them in-context and can fix without waiting for CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pull the file path out of the hook's stdin JSON without requiring jq.
input="$(cat)"
file_path="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
tool_input = data.get("tool_input", {})
path = tool_input.get("file_path") or tool_input.get("path") or ""
print(path)
')"

# Only check Swift files inside the Kioku app target.
case "$file_path" in
  "$ROOT_DIR"/Kioku/*.swift) ;;
  *) exit 0 ;;
esac

# Run scoped check; quiet on success, surface findings on failure.
bash "$ROOT_DIR/scripts/validate_invariants.sh" --files "$file_path" --quiet

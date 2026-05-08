#!/usr/bin/env bash
# One-shot installer for the Kioku MCP server, intended to run on a Raspberry Pi
# (or any always-on Linux box on the same LAN as the iPhone running Kioku).
#
# Idempotent: safe to re-run after pulling new commits — it reinstalls deps and
# rebuilds, but won't clobber your environment file unless --reset-env is passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.local"
RESET_ENV=0

for arg in "$@"; do
  case "$arg" in
    --reset-env) RESET_ENV=1 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install-on-pi.sh [--reset-env]

  --reset-env   Overwrite .env.local with a fresh template (otherwise preserved).

After install:
  1. Edit  tools/mcp-server/.env.local  with the URL/token from Kioku → Settings → MCP Bridge → Copy Connection Info.
  2. Smoke-test:   node dist/index.js   (it should print "connected to http://...").
  3. Register with Claude Code — see README.md "Run via Claude Code / Claude Desktop".
USAGE
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Checking Node.js"
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is not installed. On Raspberry Pi OS:" >&2
  echo "  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -" >&2
  echo "  sudo apt-get install -y nodejs" >&2
  exit 1
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "Node.js 20+ required, found $(node -v)." >&2
  exit 1
fi
echo "    using node $(node -v)"

echo "==> Installing dependencies"
cd "$SCRIPT_DIR"
npm install --silent

echo "==> Building TypeScript"
npm run build --silent

if [ ! -f "$ENV_FILE" ] || [ "$RESET_ENV" -eq 1 ]; then
  echo "==> Writing $ENV_FILE template"
  cat > "$ENV_FILE" <<'TEMPLATE'
# Paste the values from Kioku → Settings → MCP Bridge → Copy Connection Info.
# This file is git-ignored.
KIOKU_BRIDGE_URL=http://CHANGE_ME:47823
KIOKU_BRIDGE_TOKEN=CHANGE_ME
TEMPLATE
  chmod 600 "$ENV_FILE"
else
  echo "==> Keeping existing $ENV_FILE (pass --reset-env to overwrite)"
fi

cat <<DONE

Install complete.

Next steps:
  1. Open Kioku on your phone, enable Settings → MCP Bridge, tap Copy Connection Info.
  2. Edit  $ENV_FILE  and paste KIOKU_BRIDGE_URL / KIOKU_BRIDGE_TOKEN.
  3. Smoke test:
       set -a && . "$ENV_FILE" && set +a && node "$SCRIPT_DIR/dist/index.js"
     (Stops with "kioku-mcp-server connected to http://..." then waits on stdio. Ctrl-C to exit.)
  4. Register with Claude Code (see README "Run via Claude Code").
DONE

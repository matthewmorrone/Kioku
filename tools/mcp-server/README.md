# Kioku MCP server

Stdio MCP server that proxies the local-network bridge inside the Kioku iOS app
so an MCP-aware client (Claude Desktop, Claude Code, the Anthropic Agent SDK)
can read and edit notes, segmentation, and furigana on a running phone or iPad.

## Topology

```
┌────────────────────┐     stdio     ┌────────────────────┐    HTTP/JSON    ┌──────────────────┐
│ Claude (Desktop /  │ ───────────▶ │ kioku-mcp-server   │ ──────────────▶ │ Kioku iOS app    │
│ Code / Agent SDK)  │              │ (this directory)   │                 │ (MCP Bridge on)  │
└────────────────────┘              └────────────────────┘                 └──────────────────┘
```

The MCP server is meant to live anywhere reachable by Claude — typically the
same machine as the client, but a Raspberry Pi on the same Wi-Fi works equally
well. The Kioku app must be foregrounded with **Settings → MCP Bridge** enabled.

## Tools exposed

| Tool                   | Description                                                  |
| ---------------------- | ------------------------------------------------------------ |
| `kioku_health`         | Verify bridge reachable + token accepted.                    |
| `kioku_list_notes`     | List every note (id, title, timestamps, segment count).      |
| `kioku_get_note`       | Full note including segments + furigana.                     |
| `kioku_create_note`    | Create a note (inserts at top).                              |
| `kioku_update_note`    | Patch title / content. Content edits clear segmentation.     |
| `kioku_delete_note`    | Permanently delete a note (saved words survive).             |
| `kioku_get_segments`   | Read one note's segment array.                               |
| `kioku_set_segments`   | Replace the segment array (concat must equal note content).  |
| `kioku_set_furigana`   | Replace the furigana annotation array on one segment.        |

## Build

```bash
cd tools/mcp-server
npm install
npm run build
```

This produces `dist/index.js` with a `node` shebang. The `bin` entry in
`package.json` exposes it as `kioku-mcp-server`.

## Configure Kioku

1. Open Kioku on the device (iPhone / iPad).
2. Go to **Settings → MCP Bridge** and toggle it on.
3. Approve the local-network permission prompt.
4. Tap **Copy Connection Info** and paste it on the host that will run this
   server. The clipboard contains:
   ```
   KIOKU_BRIDGE_URL=http://<lan-ip>:<port>
   KIOKU_BRIDGE_TOKEN=<random>
   ```
5. Keep Kioku in the foreground. iOS suspends background sockets, so the
   listener only runs while the app is on screen.

## Run via Claude Code / Claude Desktop

Add this to your client's MCP server registration (`claude_desktop_config.json`
on macOS, the equivalent on the Pi for Claude Code):

```json
{
  "mcpServers": {
    "kioku": {
      "command": "node",
      "args": ["/absolute/path/to/Kioku/tools/mcp-server/dist/index.js"],
      "env": {
        "KIOKU_BRIDGE_URL": "http://192.168.1.42:47823",
        "KIOKU_BRIDGE_TOKEN": "paste-token-here"
      }
    }
  }
}
```

## Manual smoke test

With the bridge enabled and `KIOKU_BRIDGE_URL` / `KIOKU_BRIDGE_TOKEN` set:

```bash
curl -s -H "Authorization: Bearer $KIOKU_BRIDGE_TOKEN" "$KIOKU_BRIDGE_URL/v1/health"
# {"status":"ok"}

curl -s -H "Authorization: Bearer $KIOKU_BRIDGE_TOKEN" "$KIOKU_BRIDGE_URL/v1/notes" | jq '.notes | length'
```

## Wire format

The bridge speaks plain HTTP/1.1 with bearer-token auth and JSON bodies. Errors
come back as `{ "error": { "code": "...", "message": "..." } }` with a non-2xx
status; tool callbacks here turn those into MCP `isError` responses so Claude
sees the bridge's reason rather than a generic network failure.

Segment edits enforce the same invariants the Swift app does: concatenated
surfaces must equal the note's content, and furigana offsets are UTF-16 within
the segment surface, half-open `[start, end)`.

## Security notes

- The bridge listens on every local interface (so a Pi on the LAN can reach it),
  but rejects every request without a valid bearer token.
- Tokens are 24 random bytes (base64url). Regenerate from Settings if the token
  is exposed; the Pi's env file must be updated to match.
- The bridge is **off by default** and only runs while the user has flipped
  the toggle. Closing Kioku kills the listener.

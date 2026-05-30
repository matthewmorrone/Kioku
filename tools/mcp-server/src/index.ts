#!/usr/bin/env node
// Entry point for the Kioku MCP server. Wires environment-driven config to the
// HTTP bridge client, registers one tool per bridge endpoint, and connects to
// stdio so Claude Desktop / Claude Code can launch this binary as an MCP server.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import { loadConfig } from "./config.js";
import { BridgeRequestError, KiokuBridgeClient } from "./client.js";
import type {
  BridgeNoteDetail,
  BridgeNoteListResponse,
  BridgeSegmentsResponse,
} from "./types.js";

// Shape used by every tool callback to keep the JSON-encoded text payload pattern
// in one place. Wrapping the bridge response as text keeps the MCP transport
// agnostic of Kioku's specific schema while still letting Claude inspect it.
function jsonContent(payload: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(payload, null, 2),
      },
    ],
  };
}

// Wraps a tool body so any BridgeRequestError lands as an MCP isError response
// instead of crashing the server. Network errors and 4xx envelopes both flow
// through this path so Claude can see why a call failed.
function safe<TArgs extends unknown[], TResult>(
  handler: (...args: TArgs) => Promise<TResult>,
) {
  return async (...args: TArgs) => {
    try {
      const result = await handler(...args);
      return jsonContent(result);
    } catch (err) {
      if (err instanceof BridgeRequestError) {
        return {
          content: [
            {
              type: "text" as const,
              text: `bridge error ${err.status} ${err.code}: ${err.message}`,
            },
          ],
          isError: true,
        };
      }
      const message = err instanceof Error ? err.message : String(err);
      return {
        content: [{ type: "text" as const, text: `unexpected error: ${message}` }],
        isError: true,
      };
    }
  };
}

// Reusable furigana annotation schema referenced by both segment-replace and the
// furigana-replace tool. UTF-16 offsets relative to the segment surface, half-open.
const furiganaSchema = z
  .object({
    start: z.number().int().nonnegative(),
    end: z.number().int().positive(),
    reading: z.string().min(1),
  })
  .strict();

const segmentSchema = z
  .object({
    surface: z.string(),
    furigana: z.array(furiganaSchema).nullable().optional(),
  })
  .strict();

async function main(): Promise<void> {
  const config = loadConfig();
  const client = new KiokuBridgeClient(config);

  const server = new McpServer(
    { name: "kioku", version: "0.1.0" },
    {
      instructions: [
        "You are connected to a running Kioku iOS app via its local-network MCP bridge.",
        "Use kioku_list_notes to discover note IDs before reading or editing.",
        "Segments must concatenate to the note's content; the bridge will reject mismatched edits.",
        "Furigana offsets are UTF-16 within each segment surface, half-open [start, end).",
      ].join(" "),
    },
  );

  server.registerTool(
    "kioku_health",
    {
      title: "Health Check",
      description: "Verify the Kioku bridge is reachable and the bearer token is accepted.",
      inputSchema: {},
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    safe(() => client.get<{ status: string }>("/v1/health")),
  );

  server.registerTool(
    "kioku_list_notes",
    {
      title: "List Notes",
      description: "Return every note's id, title, timestamps, segment count, and audio presence.",
      inputSchema: {},
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    safe(() => client.get<BridgeNoteListResponse>("/v1/notes")),
  );

  server.registerTool(
    "kioku_get_note",
    {
      title: "Get Note",
      description: "Return one note's full content including segments and furigana annotations.",
      inputSchema: {
        id: z.string().uuid().describe("Note UUID returned by kioku_list_notes."),
      },
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    safe(({ id }: { id: string }) =>
      client.get<BridgeNoteDetail>(`/v1/notes/${encodeURIComponent(id)}`),
    ),
  );

  server.registerTool(
    "kioku_create_note",
    {
      title: "Create Note",
      description: "Create a new note. Inserts at the top of the notes list.",
      inputSchema: {
        title: z.string().optional(),
        content: z.string().optional(),
      },
    },
    safe(({ title, content }: { title?: string; content?: string }) =>
      client.post<BridgeNoteDetail>("/v1/notes", {
        title: title ?? "",
        content: content ?? "",
      }),
    ),
  );

  server.registerTool(
    "kioku_update_note",
    {
      title: "Update Note",
      description:
        "Update a note's title and/or content. Updating content clears segmentation so the segmenter recomputes.",
      inputSchema: {
        id: z.string().uuid(),
        title: z.string().optional(),
        content: z.string().optional(),
      },
    },
    safe(({ id, title, content }: { id: string; title?: string; content?: string }) => {
      const body: { title?: string; content?: string } = {};
      if (title !== undefined) body.title = title;
      if (content !== undefined) body.content = content;
      return client.patch<BridgeNoteDetail>(`/v1/notes/${encodeURIComponent(id)}`, body);
    }),
  );

  server.registerTool(
    "kioku_delete_note",
    {
      title: "Delete Note",
      description: "Permanently delete a note. Saved words from this note are not deleted.",
      inputSchema: {
        id: z.string().uuid(),
      },
      annotations: { destructiveHint: true },
    },
    safe(async ({ id }: { id: string }) => {
      await client.delete(`/v1/notes/${encodeURIComponent(id)}`);
      return { ok: true };
    }),
  );

  server.registerTool(
    "kioku_get_segments",
    {
      title: "Get Segments",
      description: "Return one note's segment array including any furigana annotations.",
      inputSchema: {
        id: z.string().uuid(),
      },
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    safe(({ id }: { id: string }) =>
      client.get<BridgeSegmentsResponse>(`/v1/notes/${encodeURIComponent(id)}/segments`),
    ),
  );

  server.registerTool(
    "kioku_set_segments",
    {
      title: "Replace Segments",
      description:
        "Replace the entire segment array for a note. Concatenated surfaces must equal the note's content.",
      inputSchema: {
        id: z.string().uuid(),
        segments: z.array(segmentSchema),
      },
    },
    safe(({ id, segments }: { id: string; segments: unknown[] }) =>
      client.put<BridgeNoteDetail>(
        `/v1/notes/${encodeURIComponent(id)}/segments`,
        { segments },
      ),
    ),
  );

  server.registerTool(
    "kioku_set_furigana",
    {
      title: "Replace Segment Furigana",
      description:
        "Replace the furigana annotation array on one segment. Offsets are UTF-16 within the segment surface, half-open [start, end). Pass an empty array to clear all readings on that segment.",
      inputSchema: {
        id: z.string().uuid(),
        segmentIndex: z.number().int().nonnegative(),
        furigana: z.array(furiganaSchema),
      },
    },
    safe(
      ({ id, segmentIndex, furigana }: { id: string; segmentIndex: number; furigana: unknown[] }) =>
        client.put<BridgeNoteDetail>(
          `/v1/notes/${encodeURIComponent(id)}/segments/${segmentIndex}/furigana`,
          { furigana },
        ),
    ),
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
  // Logging on stderr because stdout is reserved for the MCP transport itself.
  console.error(`kioku-mcp-server connected to ${config.baseUrl}`);
}

main().catch((err) => {
  console.error("kioku-mcp-server fatal:", err);
  process.exit(1);
});

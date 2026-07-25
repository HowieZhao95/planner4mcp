#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { EventKitBridge, BridgeError } from "./bridge.js";
import { TOOLS, callTool } from "./tools.js";

const INSTRUCTIONS = `Read and write the user's Apple Calendar and Reminders on this Mac, via EventKit.

Working rules:
- For open questions about what the user has on ("what's today", "how's my week", "what am I behind on"), start with
  list_agenda: one time-ordered view of events and dated reminders together, plus what is overdue. Reach for
  list_events or list_reminders when the user clearly means only one kind, or when you need fields the agenda omits.
- Events and reminders are different kinds of object and stay that way: an event occupies a span of time, a reminder
  is a due point with a completion state. They live in one store but cannot be converted into each other, and a
  reminder has no end time. Do not describe them to the user as two systems that need syncing.
- Ids are opaque. Always resolve names to ids with list_calendars / list_events / list_reminders before editing or deleting.
- Dates accept ISO-8601 with offset, local wall-clock without offset, or date-only (which means all-day / no time).
- Recurring events are returned as individual occurrences. To change or delete just one, pass its occurrenceDate;
  to change it and everything after, also pass span="future".
- delete_events, delete_reminders and delete_calendar are two-step. The first call only previews. Show the preview to
  the user in their own words and get an explicit yes before calling again with confirm=true. Deletion is not undoable.
- To clear a scheduled item the user has finished, prefer complete_reminders over delete_reminders.
- Calendars with writable=false (subscribed feeds, holidays, birthdays) cannot be modified. Say so rather than retrying.
- EventKit does not expose three things the user can see in Reminders.app: list groups (the folder holding several
  lists), sections within a list, and subtask nesting. Lists and reminders come back flat. Do not infer, invent or
  promise this structure, and do not try to work around it by writing to hidden fields — there are none. If the user
  asks for it, say it is unavailable through Apple's API and offer a list-per-section or a title convention instead.`;

async function main(): Promise<void> {
  const bridge = new EventKitBridge();

  const server = new Server(
    { name: "planner4mcp", version: "0.1.0" },
    { capabilities: { tools: {} }, instructions: INSTRUCTIONS },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS,
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    try {
      const result = await callTool(bridge, name, (args ?? {}) as Record<string, any>);
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      };
    } catch (error) {
      const payload =
        error instanceof BridgeError
          ? { error: error.code, message: error.message }
          : {
              error: "tool_failed",
              message: error instanceof Error ? error.message : String(error),
            };
      return {
        isError: true,
        content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
      };
    }
  });

  const shutdown = () => {
    bridge.stop();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  await server.connect(new StdioServerTransport());
}

main().catch((error) => {
  // stdout is the MCP channel; diagnostics must go to stderr.
  console.error("[planner4mcp] fatal:", error);
  process.exit(1);
});

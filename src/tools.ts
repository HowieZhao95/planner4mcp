import type { EventKitBridge } from "./bridge.js";

export interface ToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

const MAX_BATCH = Number(process.env.PLANNER4MCP_MAX_BATCH ?? 50);

// ---------------------------------------------------------------- date helpers

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

/** Local `yyyy-MM-dd`, offset by whole days. The Swift side reads it as local midnight. */
function localDay(offsetDays = 0): string {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** ISO-8601 with the machine's real UTC offset, not Z. */
function localNowISO(): string {
  const d = new Date();
  const offset = -d.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
    `${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
  );
}

function timeZoneName(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

// ---------------------------------------------------------------- schema parts

const DATE_HINT =
  "ISO-8601 (`2026-07-25T14:00:00+08:00`), local wall-clock (`2026-07-25T14:00`), or date-only (`2026-07-25`).";

const recurrenceSchema = {
  type: "object",
  description:
    "Repeat rule. Combine `frequency` + `interval` with the narrowing fields. " +
    "For 'the 2nd Monday of every month' use frequency=monthly, daysOfTheWeek=[monday], setPositions=[2]. " +
    "For 'the last Friday' use setPositions=[-1]. Pass null to clear an existing rule.",
  properties: {
    frequency: {
      type: "string",
      enum: ["daily", "weekly", "monthly", "yearly"],
    },
    interval: {
      type: "integer",
      minimum: 1,
      description: "Every N periods. Default 1.",
    },
    daysOfTheWeek: {
      type: "array",
      items: {
        type: "string",
        enum: [
          "monday",
          "tuesday",
          "wednesday",
          "thursday",
          "friday",
          "saturday",
          "sunday",
        ],
      },
    },
    daysOfTheMonth: {
      type: "array",
      items: { type: "integer" },
      description: "1..31, or negative to count from the end of the month.",
    },
    monthsOfTheYear: { type: "array", items: { type: "integer" } },
    weeksOfTheYear: { type: "array", items: { type: "integer" } },
    daysOfTheYear: { type: "array", items: { type: "integer" } },
    setPositions: {
      type: "array",
      items: { type: "integer" },
      description:
        "Pick the Nth match within each period (1 = first, -1 = last).",
    },
    end: {
      type: "object",
      description: "Stop condition. Use one of the two fields, or omit to repeat forever.",
      properties: {
        until: { type: "string", description: `Last date. ${DATE_HINT}` },
        occurrenceCount: { type: "integer", minimum: 1 },
      },
    },
  },
  required: ["frequency"],
} as const;

const alarmsSchema = {
  type: "array",
  description:
    "Alerts. Pass an empty array to remove all alarms, or omit to leave them untouched.",
  items: {
    type: "object",
    properties: {
      relativeOffsetMinutes: {
        type: "integer",
        description:
          "Minutes relative to the start/due time. Negative = before (e.g. -15).",
      },
      absoluteDate: { type: "string", description: `Fixed alert time. ${DATE_HINT}` },
      location: {
        type: "object",
        description: "Geofenced alert.",
        properties: {
          title: { type: "string" },
          latitude: { type: "number" },
          longitude: { type: "number" },
          radius: { type: "number", description: "Metres." },
          proximity: { type: "string", enum: ["enter", "leave"] },
        },
        required: ["title"],
      },
    },
  },
} as const;

// ---------------------------------------------------------------- tool catalog

export const TOOLS: ToolDef[] = [
  {
    name: "check_access",
    description:
      "Report whether macOS has granted this server access to Calendars and Reminders, plus today's date and timezone. " +
      "Call this first if any other tool fails with a permission error.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "list_accounts",
    description:
      "List the underlying accounts (iCloud, Local, Exchange, subscribed feeds) that own calendars and reminder lists. " +
      "Use the returned `id` as `sourceId` when creating a calendar in a specific account.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "list_calendars",
    description:
      "List calendars and/or reminder lists, with their ids, colors, owning account, writability, and which one is the default. " +
      "Every other tool takes these ids. Read-only (subscribed / delegated) calendars are flagged with writable=false.",
    inputSchema: {
      type: "object",
      properties: {
        entity: {
          type: "string",
          enum: ["all", "event", "reminder"],
          description:
            "`event` = Calendar app calendars, `reminder` = Reminders app lists. Default `all`.",
        },
      },
    },
  },
  {
    name: "create_calendar",
    description: "Create a new calendar or reminder list.",
    inputSchema: {
      type: "object",
      properties: {
        entity: { type: "string", enum: ["event", "reminder"] },
        title: { type: "string" },
        color: { type: "string", description: "Hex, e.g. #FF8800." },
        sourceId: {
          type: "string",
          description:
            "Account id or title from list_accounts. Defaults to the account holding the current default calendar.",
        },
      },
      required: ["entity", "title"],
    },
  },
  {
    name: "update_calendar",
    description: "Rename or recolor an existing calendar or reminder list.",
    inputSchema: {
      type: "object",
      properties: {
        entity: { type: "string", enum: ["event", "reminder"] },
        id: { type: "string" },
        title: { type: "string" },
        color: { type: "string", description: "Hex, e.g. #FF8800." },
      },
      required: ["entity", "id"],
    },
  },
  {
    name: "delete_calendar",
    description:
      "Delete a calendar or reminder list AND everything inside it. Two-step: the first call previews what would be removed; " +
      "pass confirm=true only after the user has explicitly approved.",
    inputSchema: {
      type: "object",
      properties: {
        entity: { type: "string", enum: ["event", "reminder"] },
        id: { type: "string" },
        confirm: {
          type: "boolean",
          description: "Must be true to actually delete. Default false = preview only.",
        },
      },
      required: ["entity", "id"],
    },
  },

  // ---- events ----
  {
    name: "list_events",
    description:
      "List calendar events in a time window, optionally filtered by text. Recurring events are expanded into their " +
      "individual occurrences — each carries `occurrenceDate`, which you must pass back when editing or deleting a single occurrence.",
    inputSchema: {
      type: "object",
      properties: {
        start: { type: "string", description: `Window start. ${DATE_HINT} Default: today.` },
        end: { type: "string", description: `Window end. ${DATE_HINT} Default: 7 days out.` },
        query: {
          type: "string",
          description: "Case-insensitive substring match on title, notes and location.",
        },
        calendarIds: {
          type: "array",
          items: { type: "string" },
          description: "Restrict to these calendars. Omit for all.",
        },
        includeCanceled: { type: "boolean" },
        limit: { type: "integer", description: "Default 200." },
      },
    },
  },
  {
    name: "get_event",
    description: "Fetch one event in full, including attendees, alarms and recurrence rule.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        occurrenceDate: {
          type: "string",
          description:
            "For a recurring event, the start of the specific occurrence you mean. Omit for the series master.",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "create_event",
    description:
      "Create a calendar event. If `start` is date-only the event is created as all-day unless you say otherwise.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" },
        start: { type: "string", description: DATE_HINT },
        end: { type: "string", description: `${DATE_HINT} Omit to use durationMinutes, or default to 1 hour.` },
        durationMinutes: { type: "integer" },
        allDay: { type: "boolean" },
        calendarId: {
          type: "string",
          description: "Omit to use the system default calendar.",
        },
        notes: { type: "string" },
        location: { type: "string" },
        url: { type: "string" },
        timeZone: { type: "string", description: "IANA name, e.g. Asia/Shanghai." },
        availability: {
          type: "string",
          enum: ["busy", "free", "tentative", "unavailable"],
        },
        recurrence: recurrenceSchema,
        alarms: alarmsSchema,
      },
      required: ["title", "start"],
    },
  },
  {
    name: "update_event",
    description:
      "Edit an existing event. Only the fields you pass are changed; pass null to clear notes/location/url. " +
      "For a recurring event, pass `occurrenceDate` to target one occurrence and set `span` to decide whether the edit " +
      "applies to that occurrence alone or to it and everything after.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        occurrenceDate: { type: "string", description: "Start of the occurrence you are editing." },
        span: {
          type: "string",
          enum: ["thisEvent", "future"],
          description: "Default `thisEvent`.",
        },
        title: { type: "string" },
        start: { type: "string", description: DATE_HINT },
        end: { type: "string", description: DATE_HINT },
        durationMinutes: { type: "integer" },
        allDay: { type: "boolean" },
        calendarId: { type: "string", description: "Move the event to another calendar." },
        notes: { type: ["string", "null"] },
        location: { type: ["string", "null"] },
        url: { type: ["string", "null"] },
        timeZone: { type: "string" },
        availability: {
          type: "string",
          enum: ["busy", "free", "tentative", "unavailable"],
        },
        recurrence: recurrenceSchema,
        alarms: alarmsSchema,
      },
      required: ["id"],
    },
  },
  {
    name: "delete_events",
    description:
      "Delete one or more events. Two-step by design: the first call returns exactly what WOULD be deleted and changes nothing. " +
      "Show that list to the user, and only call again with confirm=true once they approve. Deletion cannot be undone.",
    inputSchema: {
      type: "object",
      properties: {
        ids: { type: "array", items: { type: "string" } },
        occurrenceDates: {
          type: "array",
          items: { type: "string" },
          description:
            "Optional, positionally matched to `ids`, to target specific occurrences of recurring events.",
        },
        span: {
          type: "string",
          enum: ["thisEvent", "future"],
          description:
            "`thisEvent` deletes only the occurrence; `future` deletes it and all later ones. Default `thisEvent`.",
        },
        confirm: {
          type: "boolean",
          description: "Must be true to actually delete. Default false = preview only.",
        },
      },
      required: ["ids"],
    },
  },
  {
    name: "find_free_time",
    description:
      "Find open slots of a given length inside working hours, based on existing busy events. " +
      "Events marked 'free' or cancelled are ignored.",
    inputSchema: {
      type: "object",
      properties: {
        start: { type: "string", description: `Search from. ${DATE_HINT} Default: today.` },
        end: { type: "string", description: `Search until. ${DATE_HINT} Default: 14 days out.` },
        durationMinutes: { type: "integer", description: "Slot length. Default 30." },
        dayStartMinutes: {
          type: "integer",
          description: "Start of the working day in minutes past midnight. Default 540 (09:00).",
        },
        dayEndMinutes: {
          type: "integer",
          description: "End of the working day in minutes past midnight. Default 1080 (18:00).",
        },
        weekdaysOnly: { type: "boolean", description: "Default true." },
        calendarIds: { type: "array", items: { type: "string" } },
        maxSlots: { type: "integer", description: "Default 20." },
      },
    },
  },

  // ---- reminders ----
  {
    name: "list_reminders",
    description:
      "List reminders, optionally filtered by list, completion state, due-date window, or text.",
    inputSchema: {
      type: "object",
      properties: {
        listIds: {
          type: "array",
          items: { type: "string" },
          description: "Reminder list ids from list_calendars. Omit for all lists.",
        },
        status: {
          type: "string",
          enum: ["incomplete", "completed", "all"],
          description: "Default `incomplete`.",
        },
        query: { type: "string", description: "Substring match on title and notes." },
        dueStart: { type: "string", description: `Only reminders due at/after this. ${DATE_HINT}` },
        dueEnd: { type: "string", description: `Only reminders due at/before this. ${DATE_HINT}` },
        onlyWithDueDate: {
          type: "boolean",
          description: "Drop reminders that have no due date at all.",
        },
        limit: { type: "integer", description: "Default 200." },
      },
    },
  },
  {
    name: "get_reminder",
    description: "Fetch one reminder in full, including alarms and recurrence rule.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
    },
  },
  {
    name: "create_reminder",
    description:
      "Create a reminder. A due date with a time does NOT alert on its own — set remindAtDueTime=true " +
      "(or pass explicit alarms) if the user wants a notification.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" },
        listId: { type: "string", description: "Omit to use the default Reminders list." },
        due: { type: "string", description: `Due date/time. ${DATE_HINT}` },
        start: { type: "string", description: `Start date/time. ${DATE_HINT}` },
        notes: { type: "string" },
        url: { type: "string" },
        priority: {
          type: ["string", "integer"],
          description: "none | low | medium | high, or 0-9 (RFC 5545: 1 highest, 9 lowest).",
        },
        remindAtDueTime: {
          type: "boolean",
          description: "Add an alarm at the due time. Default false.",
        },
        completed: { type: "boolean" },
        timeZone: { type: "string", description: "IANA name, e.g. Asia/Shanghai." },
        recurrence: recurrenceSchema,
        alarms: alarmsSchema,
      },
      required: ["title"],
    },
  },
  {
    name: "update_reminder",
    description:
      "Edit a reminder. Only the fields you pass are changed; pass null for due/start/notes/url to clear them. " +
      "Can also move the reminder to another list or toggle completion.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        title: { type: "string" },
        listId: { type: "string", description: "Move to another reminder list." },
        due: { type: ["string", "null"], description: DATE_HINT },
        start: { type: ["string", "null"], description: DATE_HINT },
        notes: { type: ["string", "null"] },
        url: { type: ["string", "null"] },
        priority: { type: ["string", "integer"] },
        completed: { type: "boolean" },
        remindAtDueTime: { type: "boolean" },
        timeZone: { type: "string" },
        recurrence: recurrenceSchema,
        alarms: alarmsSchema,
      },
      required: ["id"],
    },
  },
  {
    name: "complete_reminders",
    description:
      "Mark reminders done (or undone). Non-destructive, so no confirmation step. " +
      "For a repeating reminder, completing it rolls it forward to the next occurrence.",
    inputSchema: {
      type: "object",
      properties: {
        ids: { type: "array", items: { type: "string" } },
        completed: { type: "boolean", description: "Default true." },
      },
      required: ["ids"],
    },
  },
  {
    name: "delete_reminders",
    description:
      "Delete one or more reminders. Two-step by design: the first call returns exactly what WOULD be deleted and changes nothing. " +
      "Show that list to the user, and only call again with confirm=true once they approve. Deletion cannot be undone. " +
      "If the user just wants something off their list, prefer complete_reminders.",
    inputSchema: {
      type: "object",
      properties: {
        ids: { type: "array", items: { type: "string" } },
        confirm: {
          type: "boolean",
          description: "Must be true to actually delete. Default false = preview only.",
        },
      },
      required: ["ids"],
    },
  },
];

// ---------------------------------------------------------------- dispatch

const DRY_RUN_NOTE =
  "DRY RUN — nothing was deleted. Review `matched` with the user, then call again with confirm=true.";

function checkBatch(ids: unknown): string[] {
  if (!Array.isArray(ids) || ids.length === 0) {
    throw new Error("`ids` must be a non-empty array");
  }
  if (ids.length > MAX_BATCH) {
    throw new Error(
      `Refusing a batch of ${ids.length}; the cap is ${MAX_BATCH}. Split it, or raise PLANNER4MCP_MAX_BATCH.`,
    );
  }
  return ids as string[];
}

export async function callTool(
  bridge: EventKitBridge,
  name: string,
  args: Record<string, any>,
): Promise<unknown> {
  const a = args ?? {};

  switch (name) {
    case "check_access": {
      const status = await bridge.call("access.status");
      return { ...status, now: localNowISO(), timeZone: timeZoneName() };
    }

    case "list_accounts":
      return bridge.call("sources.list");

    case "list_calendars":
      return { calendars: await bridge.call("calendars.list", { entity: a.entity ?? "all" }) };

    case "create_calendar":
      return bridge.call("calendars.create", a);

    case "update_calendar":
      return bridge.call("calendars.update", a);

    case "delete_calendar": {
      const result: any = await bridge.call("calendars.delete", {
        ...a,
        dryRun: a.confirm !== true,
      });
      return a.confirm === true ? result : { ...result, note: DRY_RUN_NOTE };
    }

    case "list_events": {
      const result: any = await bridge.call("events.list", {
        ...a,
        start: a.start ?? localDay(0),
        end: a.end ?? localDay(7),
      });
      return { now: localNowISO(), timeZone: timeZoneName(), ...result };
    }

    case "get_event":
      return bridge.call("events.get", a);

    case "create_event":
      return bridge.call("events.create", a);

    case "update_event":
      return bridge.call("events.update", a);

    case "delete_events": {
      const ids = checkBatch(a.ids);
      const result: any = await bridge.call("events.delete", {
        ...a,
        ids,
        dryRun: a.confirm !== true,
      });
      return a.confirm === true ? result : { ...result, note: DRY_RUN_NOTE };
    }

    case "find_free_time": {
      const result: any = await bridge.call("events.freeTime", {
        ...a,
        start: a.start ?? localDay(0),
        end: a.end ?? localDay(14),
      });
      return { now: localNowISO(), timeZone: timeZoneName(), ...result };
    }

    case "list_reminders": {
      const result: any = await bridge.call("reminders.list", a);
      return { now: localNowISO(), timeZone: timeZoneName(), ...result };
    }

    case "get_reminder":
      return bridge.call("reminders.get", a);

    case "create_reminder":
      return bridge.call("reminders.create", a);

    case "update_reminder":
      return bridge.call("reminders.update", a);

    case "complete_reminders":
      return bridge.call("reminders.complete", {
        ids: checkBatch(a.ids),
        completed: a.completed ?? true,
      });

    case "delete_reminders": {
      const ids = checkBatch(a.ids);
      const result: any = await bridge.call("reminders.delete", {
        ids,
        dryRun: a.confirm !== true,
      });
      return a.confirm === true ? result : { ...result, note: DRY_RUN_NOTE };
    }

    default:
      throw new Error(`Unknown tool '${name}'`);
  }
}

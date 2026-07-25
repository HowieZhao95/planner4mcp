# planner4mcp

MCP server for **Apple Calendar** and **Apple Reminders** on macOS — full CRUD over both,
backed by EventKit rather than AppleScript.

- **MCP layer**: TypeScript, `@modelcontextprotocol/sdk`, stdio transport.
- **Data layer**: a small Swift binary (`build/ekbridge`) that talks to EventKit and speaks
  newline-delimited JSON over stdin/stdout. It is kept warm as a child process, so the
  `EKEventStore` is not rebuilt on every call.

Why not AppleScript: the Reminders scripting dictionary is famously slow (seconds per query on
large lists) and cannot express recurrence rules, alarms, or priorities. EventKit can.

---

## Requirements

- macOS 14 or later (uses `requestFullAccessToEvents` / `requestFullAccessToReminders`)
- Xcode command line tools (`swiftc`)
- Node.js 18+ — **note the default `node` on this machine is v16, which is too old**.
  Use `/opt/homebrew/bin/node` or `nvm use 24`.

## Build

```bash
npm install && npm run build
```

This compiles `swift/ekbridge.swift` into `build/ekbridge` and the TypeScript into `dist/`.

The build embeds `swift/Info.plist` into the binary's `__TEXT,__info_plist` section. Without
that section macOS kills the process the instant it touches EventKit, because there is no usage
description string. The binary is then ad-hoc signed with a stable identifier so TCC can
remember the grant across rebuilds.

## Granting access (do this once)

macOS gates Calendars and Reminders behind TCC. **The grant attaches to the app that launches
the server, not to the binary itself** — a command-line tool inherits its parent's TCC identity.
So:

- Using it from **Claude Code / Claude Desktop** → the prompt appears for *Claude*, and the
  grant shows up under that app in System Settings.
- Using it from a **terminal** → the grant shows up under *Terminal* / *iTerm*.

To trigger the prompts yourself, run this in a normal Terminal window (not through a tool, or
the dialog has no GUI session to appear in and is silently denied):

```bash
cd /Users/howiez/dev-Loc/Project/planner4mcp && ./build/ekbridge --request-access
```

Check the state at any time — this never prompts:

```bash
./build/ekbridge access.status
```

`notDetermined` means no prompt has been answered yet. `denied` means you have to flip it
manually in **System Settings › Privacy & Security › Calendars** (and **› Reminders**) for the
host app, then restart that app.

## Registering with Claude Code

```bash
claude mcp add planner4mcp -- /opt/homebrew/bin/node /Users/howiez/dev-Loc/Project/planner4mcp/dist/index.js
```

Or in a client's JSON config:

```json
{
  "mcpServers": {
    "planner4mcp": {
      "command": "/opt/homebrew/bin/node",
      "args": ["/Users/howiez/dev-Loc/Project/planner4mcp/dist/index.js"]
    }
  }
}
```

---

## Tools

### Access & structure

| Tool | Purpose |
| --- | --- |
| `check_access` | TCC status for both entity types, plus today's date and timezone |
| `list_accounts` | Underlying accounts (iCloud, Local, Exchange, subscribed) |
| `list_calendars` | Calendars and/or reminder lists — ids, color, owner account, writability, default flag |
| `create_calendar` | New calendar or reminder list |
| `update_calendar` | Rename / recolor |
| `delete_calendar` | Delete a calendar and its contents (two-step) |

### Events

| Tool | Purpose |
| --- | --- |
| `list_events` | Events in a window, optional text filter; recurring events expanded per occurrence |
| `get_event` | One event in full — attendees, alarms, recurrence |
| `create_event` | Create, incl. all-day, recurrence, alarms, availability, timezone |
| `update_event` | Partial edit; `span` picks this-occurrence vs this-and-future |
| `delete_events` | Batch delete (two-step) |
| `find_free_time` | Open slots of N minutes inside working hours |

### Reminders

| Tool | Purpose |
| --- | --- |
| `list_reminders` | Filter by list, completion state, due window, text |
| `get_reminder` | One reminder in full |
| `create_reminder` | Create, incl. due/start, priority, recurrence, alarms |
| `update_reminder` | Partial edit; can move between lists and toggle completion |
| `complete_reminders` | Batch mark done / undone |
| `delete_reminders` | Batch delete (two-step) |

## Safety model

Deletion is the only thing that cannot be undone, so all three delete tools are **two-step**:

1. First call returns `dryRun: true` and a `matched` list of exactly what would be removed.
   Nothing is touched.
2. Only a second call with `confirm: true` actually deletes.

Batches are capped at 50 ids (`PLANNER4MCP_MAX_BATCH` to change). Read-only calendars —
subscribed feeds, Holidays, Birthdays — are rejected with a clear error rather than failing
opaquely.

## Date handling

Every date field accepts:

- full ISO-8601 with offset — `2026-07-25T14:00:00+08:00`
- local wall-clock — `2026-07-25T14:00`
- date-only — `2026-07-25`, meaning all-day (events) or a due date with no time (reminders)

Note that EventKit does **not** alert on a reminder's due time by itself. Pass
`remindAtDueTime: true` (or explicit `alarms`) when the user wants a notification.

## Recurrence

RFC 5545 semantics via `EKRecurrenceRule`:

```jsonc
// every other Tuesday, 10 times
{ "frequency": "weekly", "interval": 2, "daysOfTheWeek": ["tuesday"],
  "end": { "occurrenceCount": 10 } }

// 2nd Monday of every month
{ "frequency": "monthly", "daysOfTheWeek": ["monday"], "setPositions": [2] }

// last Friday of every quarter, until a date
{ "frequency": "monthly", "interval": 3, "daysOfTheWeek": ["friday"],
  "setPositions": [-1], "end": { "until": "2027-01-01" } }
```

Pass `"recurrence": null` on an update to strip an existing rule.

## Development

```bash
npm run build:bridge          # Swift only
npm run build:ts              # TypeScript only

# talk to the bridge directly, bypassing MCP
./build/ekbridge calendars.list '{"entity":"reminder"}'
./build/ekbridge events.list '{"start":"2026-07-25","end":"2026-08-01"}'

# drive the MCP server as a client
node scripts/smoke.mjs                              # initialize + tools/list
node scripts/smoke.mjs list_calendars '{}'
node scripts/smoke.mjs create_reminder '{"title":"test","due":"2026-07-26T09:00"}'
```

Bridge methods: `ping`, `access.status`, `access.request`, `sources.list`, `calendars.{list,create,update,delete}`,
`events.{list,get,create,update,delete,freeTime}`, `reminders.{list,get,create,update,delete,complete}`.

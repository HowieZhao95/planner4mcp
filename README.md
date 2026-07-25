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

This compiles `swift/ekbridge.swift` into an **app bundle**, `build/ekbridge.app`, with
`build/ekbridge` left as a symlink to the executable inside it. The TypeScript goes to `dist/`.

## Granting access (do this once)

```bash
./build/ekbridge --request-access   # prompts
./build/ekbridge access.status      # never prompts, just reports
```

Both should end up `fullAccess`. The grant is recorded against this project's own bundle
identifier, `com.howiez.planner4mcp.ekbridge`, and appears in **System Settings › Privacy &
Security › Calendars** (and **› Reminders**) as *planner4mcp*.

### Why this is not as simple as it looks

macOS attributes a TCC request to the **responsible process**, which for a spawned child is
normally the host app — and `tccd` refuses to display a consent dialog if that app's `Info.plist`
does not carry the matching usage description. It does not error; it silently denies and leaves
the status at `notDetermined` forever.

Claude Code (`com.anthropic.claude-code`) declares usage strings for the microphone, Apple
Events and the local network — nothing for Calendars or Reminders. Claude Desktop is the same.
So an EventKit request made under either of them can never succeed, no matter what the child
binary declares. Terminals do not have this problem: they carry no calendar usage string either,
but the user can grant *Terminal* itself access in System Settings, and the child inherits it.

Three things in the build exist specifically to get around this, and removing any of them breaks
access in a way that looks like a permissions mistake rather than a bug:

1. **`swift/Info.plist` is embedded into `__TEXT,__info_plist`.** Without the usage description
   strings the kernel kills the process the instant it touches EventKit.
2. **The output is an `.app` bundle, not a bare executable.** `tccd` only prompts for a process
   it can resolve to a real bundle with an identifier and a display name.
3. **The binary re-execs itself with `responsibility_spawnattrs_setdisclaim()`** before touching
   EventKit (see `reexecDisclaimingResponsibility` in `swift/ekbridge.swift`). That is what
   severs the inherited attribution and makes the process its own responsible process, so TCC
   reads *this* bundle's usage strings instead of the host's. `POSIX_SPAWN_SETEXEC` replaces the
   process image rather than forking, so the pid and the inherited stdio pipes survive intact.
   The symbol is private API, resolved via `dlsym` so that a future macOS dropping it degrades
   to the old behaviour instead of failing to launch.

The bundle is ad-hoc signed with a stable `--identifier`. Note that ad-hoc signatures are pinned
by cdhash, so **rebuilding the Swift can re-trigger the consent prompt**. To wipe the grant and
start over:

```bash
tccutil reset Calendar com.howiez.planner4mcp.ekbridge
tccutil reset Reminders com.howiez.planner4mcp.ekbridge
```

## Registering with a client

Point clients at `bin/planner4mcp` rather than at `node dist/index.js`. The launcher resolves
the repo root and a Node ≥ 18 at spawn time, so the entry survives a Node upgrade, an nvm
switch, or being copied to a Mac where Homebrew lives at `/usr/local` instead of
`/opt/homebrew`.

```bash
claude mcp add planner4mcp -- /path/to/planner4mcp/bin/planner4mcp
```

```json
{
  "mcpServers": {
    "planner4mcp": { "command": "/path/to/planner4mcp/bin/planner4mcp" }
  }
}
```

`scripts/register-desktop.sh` writes that entry into Claude Desktop's config for you. It backs
the file up first and leaves any other servers alone.

### Configs that sync between machines

A `.mcp.json` living in a synced folder — an iCloud-backed Obsidian vault, a shared git repo —
lands on every machine, so an absolute path in it is guaranteed to be wrong on one of them.
Claude Code expands `${VAR}` and `${VAR:-default}`, so write it as:

```json
{
  "mcpServers": {
    "planner4mcp": {
      "command": "${PLANNER4MCP_HOME:-/absolute/path/on/your/main/mac}/bin/planner4mcp"
    }
  }
}
```

Then each machine only has to define `PLANNER4MCP_HOME`. Note that exporting it from `.zshrc`
covers terminal use only — **GUI apps do not inherit the login shell's environment**, so Claude
Desktop (and the claude-code it embeds) would silently fall back to the default path.
`scripts/setup-new-mac.sh` handles both: it appends the export to `.zshrc` *and* installs a
LaunchAgent that runs `launchctl setenv` at login so GUI processes see it too.

## Using it on another Mac

This server reads the local EventKit store, and that store is what iCloud syncs. So on a second
Mac signed into the same Apple Account **the data is already the same** — what does not carry
over is the software and the permission grant.

Requirements on the second machine: macOS 14+ (the binary's deployment target), Xcode or the
Command Line Tools (for `swiftc`), and Node 18+.

```bash
git clone <your remote> planner4mcp && cd planner4mcp
npm install && npm run build
which node && claude mcp add planner4mcp -- $(which node) $(pwd)/dist/index.js
```

Copying the directory instead of cloning works too, but delete `node_modules/`, `dist/` and
`build/` first and rebuild. **The Swift binary does not travel between machines**: the build
script picks the architecture from `uname -m` (arm64 vs x86_64), and the ad-hoc signature has to
be re-established for TCC anyway. Note also that the Node path differs — Homebrew is
`/opt/homebrew/bin/node` on Apple Silicon, `/usr/local/bin/node` on Intel.

**Access has to be granted again.** TCC is a per-machine database; it is not synced by iCloud
and has nothing to do with the Apple Account. Run `./build/ekbridge --request-access` once on
the new machine.

### Two things that bite

**Local calendars do not sync.** Only calendars and reminder lists whose source is iCloud appear
on other devices. If `create_calendar` is called without `sourceId` it may land in the "On My
Mac" local account, where nothing else will ever see it. Check `list_accounts` and pass the
iCloud account's id explicitly. For existing calendars, `list_calendars` reports `source.type` —
`calDAV` with the title `iCloud` is the synced one.

**Identifiers are device-local.** `calendarIdentifier` and `eventIdentifier` are local to one
Mac; the same event has different ids on two machines. This is invisible in normal use, because
every tool call lists first and acts on ids from that same response within one session. It only
breaks if ids are persisted somewhere or passed between machines — looking up an id on Mac A and
deleting it on Mac B will fail. EventKit's `calendarItemExternalIdentifier` is the cross-device
stable one; it is not currently exposed, and would need to be added if that workflow is wanted.

### What will not work

iPhone and iPad cannot run an MCP server at all. Linux and Windows have no EventKit; reaching
the same data there means talking CalDAV to iCloud directly, which is a separate implementation
— Apple ID plus an app-specific password for auth, hand-built RFC 5545 for recurrence, and
noticeably weaker support for reminders. That is worth designing on its own rather than bolting
onto this codebase.

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

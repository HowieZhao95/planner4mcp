# Changelog

## 0.2.0 — 2026-10-28

First version cut. 0.1.0 was the initial tree and was never tagged. This entry covers what landed after that tree, plus the SDK and tooling work in the same release.

A git tag and a GitHub Release are **not** created by this changelog. Cut those by hand when you want to publish the version.

### Added

- `list_agenda`: events and dated reminders in one day-grouped timeline, with overdue reminders and optional collapsing of mirrored event/reminder pairs.
- `externalId` on events, reminders, and agenda items (`EKCalendarItem.calendarItemExternalIdentifier`). A collapsed pair also carries `reminderExternalId`. See the README for Exchange, local calendars, and recurring occurrences.
- `create_calendar` and `update_calendar` return `entity` and `isDefault`, matching `list_calendars`.
- MCP tool annotations: lists, gets, `find_free_time`, `list_agenda`, and `check_access` are read-only; creates are non-idempotent; updates are idempotent; deletes and `complete_reminders` are destructive. Completing a repeating reminder rolls it forward, so `complete_reminders` is not idempotent.
- `scripts/register-cursor.sh` and a Cursor `mcp.json` example that points at `bin/planner4mcp`.
- Verify coverage for `list_agenda` and for `find_free_time` with multi-day all-day events (`allDayIsBusy`).
- `npm test` (build + live EventKit verify) and `npm run smoke` (TypeScript build + protocol handshake).
- Linux CI that runs `npm ci` and `npm run build:ts` only.

### Changed

- `@modelcontextprotocol/sdk` moved from 1.29.0 to 1.32.2. `zod` is a direct dependency, which the SDK requires as a peer. Smoke and verify negotiate `LATEST_PROTOCOL_VERSION` from the installed SDK (`2025-11-25` on 1.32.2).

### Fixed

- `find_free_time` no longer treats all-day events as blocking the whole day. Pass `allDayIsBusy: true` for the previous behavior. Multi-day all-day markers were wiping every slot in range.
- The EventKit bridge re-execs as its own TCC responsible process, inside an app bundle, so Calendar and Reminders consent can be granted when the host app does not declare those usage strings.

## 0.1.0 — 2026-07-25

Initial MCP server: EventKit bridge, calendar and reminder CRUD, recurrence, alarms, and two-step deletes.

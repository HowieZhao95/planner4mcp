#!/usr/bin/env node
// End-to-end self test: drives the MCP server as a real client and exercises
// the full CRUD surface against live EventKit data.
//
// Everything it creates is prefixed "planner4mcp selftest" and removed at the
// end, including on failure.
//
//   /opt/homebrew/bin/node scripts/verify.mjs

import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const PREFIX = "planner4mcp selftest";

// ---------------------------------------------------------------- MCP client

const proc = spawn(process.execPath, [resolve(root, "dist", "index.js")], {
  stdio: ["pipe", "pipe", "inherit"],
});

let buffer = "";
const pending = new Map();
let nextId = 1;

proc.stdout.setEncoding("utf8");
proc.stdout.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    const entry = pending.get(msg.id);
    if (entry) {
      pending.delete(msg.id);
      entry(msg);
    }
  }
});

function rpc(method, params) {
  const id = nextId++;
  return new Promise((res) => {
    pending.set(id, res);
    proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}

/** Returns { ok, data } — ok=false means the tool reported an error. */
async function call(name, args = {}) {
  const res = await rpc("tools/call", { name, arguments: args });
  const text = res.result?.content?.[0]?.text ?? "{}";
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { raw: text };
  }
  return { ok: !res.result?.isError, data };
}

/** Throws on tool error. */
async function must(name, args = {}) {
  const { ok, data } = await call(name, args);
  if (!ok) {
    throw new Error(`${name} failed: ${data.error ?? "?"} — ${data.message ?? ""}`);
  }
  return data;
}

// ---------------------------------------------------------------- assertions

let passed = 0;
let failed = 0;
const failures = [];

function check(label, condition, detail = "") {
  if (condition) {
    passed++;
    console.log(`  PASS  ${label}`);
  } else {
    failed++;
    failures.push(label);
    console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

function section(title) {
  console.log(`\n== ${title}`);
}

// ---------------------------------------------------------------- date helpers

const pad = (n) => String(n).padStart(2, "0");
function dayOffset(days) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// ---------------------------------------------------------------- the run

const created = { events: [], reminders: [], lists: [] };

async function run() {
  await rpc("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "verify", version: "0" },
  });
  proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })}\n`);

  // ---- access
  section("Access");
  const access = await must("check_access");
  console.log(`  events=${access.events} reminders=${access.reminders} tz=${access.timeZone}`);
  if (!access.eventsUsable || !access.remindersUsable) {
    console.log("\n  Access not granted for this host app. Run in this same terminal:");
    console.log("    ./build/ekbridge --request-access\n");
    process.exit(2);
  }
  check("calendar + reminder access granted", true);

  // ---- calendars
  section("Calendars / lists");
  const { calendars } = await must("list_calendars", { entity: "all" });
  const eventCals = calendars.filter((c) => c.entity === "event");
  const reminderLists = calendars.filter((c) => c.entity === "reminder");
  check("found at least one calendar", eventCals.length > 0);
  check("found at least one reminder list", reminderLists.length > 0);

  const defaultCal = eventCals.find((c) => c.isDefault && c.writable) ?? eventCals.find((c) => c.writable);
  const defaultList = reminderLists.find((c) => c.isDefault && c.writable) ?? reminderLists.find((c) => c.writable);
  check("a writable calendar exists", !!defaultCal, "all calendars are read-only");
  check("a writable reminder list exists", !!defaultList);
  if (!defaultCal || !defaultList) throw new Error("nothing writable to test against");
  console.log(`  using calendar "${defaultCal.title}" and list "${defaultList.title}"`);

  const readOnly = calendars.filter((c) => !c.writable);
  console.log(`  ${calendars.length} total, ${readOnly.length} read-only`);

  // ---- calendar CRUD (on a throwaway reminder list)
  section("Calendar CRUD");
  const newList = await must("create_calendar", {
    entity: "reminder",
    title: `${PREFIX} list`,
    color: "#FF8800",
  });
  created.lists.push(newList.id);
  check("create_calendar returns an id", !!newList.id);
  check("create_calendar applied the color", newList.color === "#FF8800", `got ${newList.color}`);

  const renamed = await must("update_calendar", {
    entity: "reminder",
    id: newList.id,
    title: `${PREFIX} list renamed`,
  });
  check("update_calendar renamed it", renamed.title === `${PREFIX} list renamed`, `got ${renamed.title}`);

  const calPreview = await must("delete_calendar", { entity: "reminder", id: newList.id });
  check("delete_calendar without confirm is a dry run", calPreview.dryRun === true);
  const stillThere = await must("list_calendars", { entity: "reminder" });
  check(
    "dry run did not delete the list",
    stillThere.calendars.some((c) => c.id === newList.id),
  );

  await must("delete_calendar", { entity: "reminder", id: newList.id, confirm: true });
  const afterDelete = await must("list_calendars", { entity: "reminder" });
  check(
    "confirmed delete removed the list",
    !afterDelete.calendars.some((c) => c.id === newList.id),
  );
  created.lists = [];

  // ---- simple event
  section("Events — create / read / update");
  const evt = await must("create_event", {
    title: `${PREFIX} meeting`,
    start: `${dayOffset(1)}T10:00`,
    end: `${dayOffset(1)}T11:00`,
    calendarId: defaultCal.id,
    notes: "created by verify.mjs",
    location: "Room A",
    alarms: [{ relativeOffsetMinutes: -15 }],
  });
  created.events.push(evt.id);
  check("create_event returns an id", !!evt.id);
  check("event start is 10:00", (evt.start ?? "").includes("T10:00"), `got ${evt.start}`);
  check("event is not all-day", evt.allDay === false);
  check("notes round-tripped", evt.notes === "created by verify.mjs");
  check("location round-tripped", evt.location === "Room A");
  check("alarm stored at -15min", evt.alarms?.[0]?.relativeOffsetMinutes === -15, JSON.stringify(evt.alarms));

  const fetched = await must("get_event", { id: evt.id });
  check("get_event returns the same event", fetched.id === evt.id && fetched.title === evt.title);

  const moved = await must("update_event", {
    id: evt.id,
    title: `${PREFIX} meeting moved`,
    start: `${dayOffset(1)}T14:00`,
    location: null,
  });
  check("update_event changed the title", moved.title === `${PREFIX} meeting moved`);
  check("update_event moved it to 14:00", (moved.start ?? "").includes("T14:00"), `got ${moved.start}`);
  check("update_event preserved the 1h duration", (moved.end ?? "").includes("T15:00"), `got ${moved.end}`);
  check("update_event cleared the location", !moved.location, `got ${moved.location}`);
  check("update_event left notes alone", moved.notes === "created by verify.mjs");

  const listed = await must("list_events", { start: dayOffset(0), end: dayOffset(3) });
  check(
    "list_events finds it",
    listed.events.some((e) => e.id === evt.id),
    `${listed.total} events in window`,
  );
  const searched = await must("list_events", {
    start: dayOffset(0),
    end: dayOffset(3),
    query: "selftest meeting moved",
  });
  check("list_events query filter works", searched.events.length === 1, `got ${searched.events.length}`);

  // ---- all-day event
  section("Events — all-day");
  const allDay = await must("create_event", {
    title: `${PREFIX} allday`,
    start: dayOffset(2),
    calendarId: defaultCal.id,
  });
  created.events.push(allDay.id);
  check("date-only start implies all-day", allDay.allDay === true);
  check("all-day start is date-only", allDay.start === dayOffset(2), `got ${allDay.start}`);

  // ---- recurring event
  section("Events — recurrence");
  const rec = await must("create_event", {
    title: `${PREFIX} weekly`,
    start: `${dayOffset(1)}T09:00`,
    durationMinutes: 30,
    calendarId: defaultCal.id,
    recurrence: { frequency: "weekly", interval: 1, end: { occurrenceCount: 4 } },
  });
  created.events.push(rec.id);
  check("recurring event created", !!rec.id && rec.hasRecurrence === true);
  check("recurrence frequency stored", rec.recurrence?.[0]?.frequency === "weekly", JSON.stringify(rec.recurrence));
  check("recurrence count stored", rec.recurrence?.[0]?.end?.occurrenceCount === 4);

  const expanded = await must("list_events", { start: dayOffset(0), end: dayOffset(30) });
  const occurrences = expanded.events.filter((e) => e.title === `${PREFIX} weekly`);
  check("recurring event expands into 4 occurrences", occurrences.length === 4, `got ${occurrences.length}`);
  check("each occurrence carries occurrenceDate", occurrences.every((o) => !!o.occurrenceDate));

  // edit only the 2nd occurrence
  const second = occurrences[1];
  const detached = await must("update_event", {
    id: second.id,
    occurrenceDate: second.occurrenceDate,
    span: "thisEvent",
    title: `${PREFIX} weekly detached`,
  });
  check("single-occurrence edit succeeded", detached.title === `${PREFIX} weekly detached`);
  const afterDetach = await must("list_events", { start: dayOffset(0), end: dayOffset(30) });
  const stillWeekly = afterDetach.events.filter((e) => e.title === `${PREFIX} weekly`);
  const detachedOnes = afterDetach.events.filter((e) => e.title === `${PREFIX} weekly detached`);
  check("only that occurrence changed", stillWeekly.length === 3 && detachedOnes.length === 1,
    `weekly=${stillWeekly.length} detached=${detachedOnes.length}`);

  // ---- free time
  section("Free time");
  const free = await must("find_free_time", {
    start: dayOffset(1),
    end: dayOffset(5),
    durationMinutes: 60,
  });
  check("find_free_time returns slots", Array.isArray(free.slots) && free.slots.length > 0,
    `${free.slots?.length} slots, ${free.busyBlocks} busy blocks`);

  // ---- reminders
  section("Reminders — create / read / update");
  const rem = await must("create_reminder", {
    title: `${PREFIX} task`,
    listId: defaultList.id,
    due: `${dayOffset(1)}T09:00`,
    notes: "verify.mjs",
    priority: "high",
    remindAtDueTime: true,
  });
  created.reminders.push(rem.id);
  check("create_reminder returns an id", !!rem.id);
  check("due date has a time", rem.due?.hasTime === true, JSON.stringify(rem.due));
  check("due time is 09:00", (rem.due?.dateTime ?? "").includes("T09:00"), rem.due?.dateTime);
  check("priority high stored as 1", rem.priority === 1 && rem.priorityLabel === "high", `got ${rem.priority}`);
  check("remindAtDueTime added an alarm", (rem.alarms?.length ?? 0) === 1, JSON.stringify(rem.alarms));

  const remUpdated = await must("update_reminder", {
    id: rem.id,
    priority: "medium",
    notes: "edited",
  });
  check("update_reminder changed priority", remUpdated.priority === 5 && remUpdated.priorityLabel === "medium");
  check("update_reminder changed notes", remUpdated.notes === "edited");
  check("update_reminder kept the due date", remUpdated.due?.hasTime === true);

  // date-only due
  const rem2 = await must("create_reminder", {
    title: `${PREFIX} task dateonly`,
    listId: defaultList.id,
    due: dayOffset(3),
  });
  created.reminders.push(rem2.id);
  check("date-only due has no time", rem2.due?.hasTime === false && rem2.due?.date === dayOffset(3),
    JSON.stringify(rem2.due));

  const remList = await must("list_reminders", { listIds: [defaultList.id], query: "selftest task" });
  check("list_reminders finds both", remList.reminders.length === 2, `got ${remList.reminders.length}`);

  const dueWindow = await must("list_reminders", {
    listIds: [defaultList.id],
    query: "selftest",
    dueStart: dayOffset(0),
    dueEnd: dayOffset(2),
  });
  check("due-window filter narrows to one", dueWindow.reminders.length === 1, `got ${dueWindow.reminders.length}`);

  section("Reminders — completion");
  const done = await must("complete_reminders", { ids: [rem.id] });
  check("complete_reminders marked it done", done.reminders?.[0]?.completed === true);
  const stillHidden = await must("list_reminders", { listIds: [defaultList.id], query: "selftest task", status: "incomplete" });
  check("completed reminder drops out of incomplete list", stillHidden.reminders.length === 1);
  const undone = await must("complete_reminders", { ids: [rem.id], completed: false });
  check("complete_reminders can undo", undone.reminders?.[0]?.completed === false);

  // ---- delete guardrails
  section("Delete guardrails");
  const remPreview = await must("delete_reminders", { ids: [rem2.id] });
  check("delete_reminders without confirm is a dry run", remPreview.dryRun === true);
  check("dry run reports what would go", remPreview.matched?.[0]?.id === rem2.id);
  check("dry run carries a note for the model", typeof remPreview.note === "string");
  const survived = await call("get_reminder", { id: rem2.id });
  check("dry run did not delete the reminder", survived.ok === true);

  await must("delete_reminders", { ids: [rem2.id], confirm: true });
  const gone = await call("get_reminder", { id: rem2.id });
  check("confirmed delete removed it", gone.ok === false && gone.data.error === "reminder_not_found",
    JSON.stringify(gone.data));
  created.reminders = created.reminders.filter((id) => id !== rem2.id);

  const evtPreview = await must("delete_events", { ids: [allDay.id] });
  check("delete_events without confirm is a dry run", evtPreview.dryRun === true);
  const evtSurvived = await call("get_event", { id: allDay.id });
  check("dry run did not delete the event", evtSurvived.ok === true);

  const overCap = await call("delete_events", { ids: Array.from({ length: 60 }, (_, i) => `x${i}`) });
  check("batch cap rejects 60 ids", overCap.ok === false && /cap is 50/.test(overCap.data.message ?? ""),
    overCap.data.message);

  // ---- recurring delete with span
  section("Delete — recurring span");
  const remaining = await must("list_events", { start: dayOffset(0), end: dayOffset(30) });
  const weeklyLeft = remaining.events.filter((e) => e.title === `${PREFIX} weekly`);
  const target = weeklyLeft[weeklyLeft.length - 1];
  await must("delete_events", {
    ids: [target.id],
    occurrenceDates: [target.occurrenceDate],
    span: "thisEvent",
    confirm: true,
  });
  const afterOne = await must("list_events", { start: dayOffset(0), end: dayOffset(30) });
  check(
    "span=thisEvent removed exactly one occurrence",
    afterOne.events.filter((e) => e.title === `${PREFIX} weekly`).length === weeklyLeft.length - 1,
  );

  // ---- read-only rejection
  if (readOnly.length > 0) {
    section("Read-only calendar rejection");
    const ro = readOnly.find((c) => c.entityTypes?.includes("event"));
    if (ro) {
      const rejected = await call("create_event", {
        title: `${PREFIX} should fail`,
        start: `${dayOffset(1)}T12:00`,
        calendarId: ro.id,
      });
      check(
        `writing to read-only "${ro.title}" is rejected`,
        rejected.ok === false && rejected.data.error === "read_only_calendar",
        JSON.stringify(rejected.data),
      );
    }
  }
}

async function cleanup() {
  section("Cleanup");
  // sweep by title as well, in case a step failed before recording an id
  try {
    const all = await must("list_events", { start: dayOffset(-1), end: dayOffset(60) });
    const mine = all.events.filter((e) => (e.title ?? "").startsWith(PREFIX));
    const ids = [...new Set(mine.map((e) => e.id))];
    if (ids.length) {
      await must("delete_events", { ids, span: "future", confirm: true });
      console.log(`  removed ${ids.length} test event series`);
    }
  } catch (e) {
    console.log(`  event cleanup failed: ${e.message}`);
  }
  try {
    const all = await must("list_reminders", { status: "all", query: PREFIX });
    const ids = all.reminders.map((r) => r.id);
    if (ids.length) {
      await must("delete_reminders", { ids, confirm: true });
      console.log(`  removed ${ids.length} test reminders`);
    }
  } catch (e) {
    console.log(`  reminder cleanup failed: ${e.message}`);
  }
  for (const id of created.lists) {
    try {
      await must("delete_calendar", { entity: "reminder", id, confirm: true });
      console.log("  removed leftover test list");
    } catch { /* already gone */ }
  }
}

let exitCode = 0;
try {
  await run();
} catch (error) {
  failed++;
  failures.push(`fatal: ${error.message}`);
  console.log(`\n  ABORTED — ${error.message}`);
} finally {
  await cleanup();
}

console.log(`\n${"=".repeat(50)}`);
console.log(`${passed} passed, ${failed} failed`);
if (failed) {
  console.log("\nFailures:");
  for (const f of failures) console.log(`  - ${f}`);
  exitCode = 1;
} else {
  console.log("All checks passed.");
}

proc.kill();
process.exit(exitCode);

// ekbridge — EventKit <-> NDJSON bridge for planner4mcp
//
// Modes:
//   ekbridge --serve                  newline-delimited JSON-RPC-ish over stdin/stdout
//   ekbridge <method> '<json args>'   one-shot, for debugging
//   ekbridge --request-access         trigger the TCC prompts and exit
//
// Wire format (serve mode), one JSON object per line:
//   in : {"id": 1, "method": "events.list", "params": {...}}
//   out: {"id": 1, "ok": true, "result": ...}
//        {"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}

import Foundation
import EventKit
import CoreGraphics
import CoreLocation

// MARK: - Errors

struct BridgeError: Error {
    let code: String
    let message: String
}

func bail(_ code: String, _ message: String) -> BridgeError {
    BridgeError(code: code, message: message)
}

// MARK: - Date helpers

let isoOut: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

let dayOnlyOut: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func isoString(_ d: Date?) -> String? {
    guard let d = d else { return nil }
    return isoOut.string(from: d)
}

func dayString(_ d: Date?) -> String? {
    guard let d = d else { return nil }
    return dayOnlyOut.string(from: d)
}

/// Accepts full ISO-8601 with offset, ISO without offset (treated as local),
/// and plain `yyyy-MM-dd` (local midnight).
func parseDate(_ s: String) throws -> Date {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFractional.date(from: s) { return d }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) { return d }

    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        df.dateFormat = fmt
        if let d = df.date(from: s) { return d }
    }
    throw bail("bad_date", "Cannot parse date/time: '\(s)'. Use ISO-8601 (2026-07-25T14:00:00+08:00) or yyyy-MM-dd.")
}

func isDateOnly(_ s: String) -> Bool {
    return s.count == 10 && s.contains("-") && !s.contains("T") && !s.contains(":")
}

func components(from date: Date, dateOnly: Bool, timeZone: TimeZone?) -> DateComponents {
    var cal = Calendar.current
    if let tz = timeZone { cal.timeZone = tz }
    var c: DateComponents
    if dateOnly {
        c = cal.dateComponents([.year, .month, .day], from: date)
    } else {
        c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        c.timeZone = cal.timeZone
    }
    return c
}

func serializeComponents(_ c: DateComponents?) -> [String: Any]? {
    guard let c = c else { return nil }
    var cal = Calendar.current
    if let tz = c.timeZone { cal.timeZone = tz }
    guard let d = cal.date(from: c) else { return nil }
    let hasTime = c.hour != nil
    var out: [String: Any] = ["hasTime": hasTime]
    if hasTime {
        out["dateTime"] = isoString(d)
    } else {
        out["date"] = dayString(d)
    }
    return out
}

// MARK: - Colors

func hexFromCGColor(_ color: CGColor?) -> String? {
    guard let color = color else { return nil }
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil) ?? color
    guard let comps = converted.components else { return nil }
    let r: CGFloat, g: CGFloat, b: CGFloat
    if comps.count >= 3 {
        r = comps[0]; g = comps[1]; b = comps[2]
    } else if comps.count >= 1 {
        r = comps[0]; g = comps[0]; b = comps[0]
    } else {
        return nil
    }
    func clamp(_ v: CGFloat) -> Int { Int(round(max(0, min(1, v)) * 255)) }
    return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
}

func cgColorFromHex(_ hex: String) throws -> CGColor {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else {
        throw bail("bad_color", "Color must be a hex string like #FF8800, got '\(hex)'")
    }
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let c = CGColor(colorSpace: srgb, components: [r, g, b, 1.0]) else {
        throw bail("bad_color", "Could not build color from '\(hex)'")
    }
    return c
}

// MARK: - Params

struct Params {
    let raw: [String: Any]

    /// Key present at all (including explicit null) — used to tell
    /// "leave unchanged" apart from "clear this field" on updates.
    func has(_ k: String) -> Bool { raw.index(forKey: k) != nil }
    /// Key present and non-null.
    func present(_ k: String) -> Bool { has(k) && !(raw[k] is NSNull) }

    func requiredString(_ k: String) throws -> String {
        guard let v = raw[k] as? String, !v.isEmpty else {
            throw bail("missing_param", "Missing required string parameter '\(k)'")
        }
        return v
    }
    func string(_ k: String) -> String? { raw[k] as? String }
    func bool(_ k: String, default def: Bool) -> Bool { (raw[k] as? NSNumber)?.boolValue ?? (raw[k] as? Bool) ?? def }
    func optBool(_ k: String) -> Bool? { (raw[k] as? NSNumber)?.boolValue ?? (raw[k] as? Bool) }
    func int(_ k: String) -> Int? { (raw[k] as? NSNumber)?.intValue }
    func double(_ k: String) -> Double? { (raw[k] as? NSNumber)?.doubleValue }
    func stringArray(_ k: String) -> [String]? { raw[k] as? [String] }
    func dict(_ k: String) -> [String: Any]? { raw[k] as? [String: Any] }
    func array(_ k: String) -> [[String: Any]]? { raw[k] as? [[String: Any]] }
    func anyArray(_ k: String) -> [Any]? { raw[k] as? [Any] }

    func date(_ k: String) throws -> Date? {
        guard let s = raw[k] as? String else { return nil }
        return try parseDate(s)
    }
    func requiredDate(_ k: String) throws -> Date {
        guard let s = raw[k] as? String else {
            throw bail("missing_param", "Missing required date parameter '\(k)'")
        }
        return try parseDate(s)
    }
}

// MARK: - Enum mapping

func sourceTypeName(_ t: EKSourceType) -> String {
    switch t {
    case .local: return "local"
    case .exchange: return "exchange"
    case .calDAV: return "calDAV"
    case .mobileMe: return "mobileMe"
    case .subscribed: return "subscribed"
    case .birthdays: return "birthdays"
    @unknown default: return "unknown"
    }
}

func calendarTypeName(_ t: EKCalendarType) -> String {
    switch t {
    case .local: return "local"
    case .calDAV: return "calDAV"
    case .exchange: return "exchange"
    case .subscription: return "subscription"
    case .birthday: return "birthday"
    @unknown default: return "unknown"
    }
}

func participantRoleName(_ r: EKParticipantRole) -> String {
    switch r {
    case .unknown: return "unknown"
    case .required: return "required"
    case .optional: return "optional"
    case .chair: return "chair"
    case .nonParticipant: return "nonParticipant"
    @unknown default: return "unknown"
    }
}

func participantStatusName(_ s: EKParticipantStatus) -> String {
    switch s {
    case .unknown: return "unknown"
    case .pending: return "pending"
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "tentative"
    case .delegated: return "delegated"
    case .completed: return "completed"
    case .inProcess: return "inProcess"
    @unknown default: return "unknown"
    }
}

func participantTypeName(_ t: EKParticipantType) -> String {
    switch t {
    case .unknown: return "unknown"
    case .person: return "person"
    case .room: return "room"
    case .resource: return "resource"
    case .group: return "group"
    @unknown default: return "unknown"
    }
}

func eventStatusName(_ s: EKEventStatus) -> String {
    switch s {
    case .none: return "none"
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled: return "canceled"
    @unknown default: return "unknown"
    }
}

func availabilityName(_ a: EKEventAvailability) -> String {
    switch a {
    case .notSupported: return "notSupported"
    case .busy: return "busy"
    case .free: return "free"
    case .tentative: return "tentative"
    case .unavailable: return "unavailable"
    @unknown default: return "unknown"
    }
}

func availabilityFromName(_ s: String) throws -> EKEventAvailability {
    switch s.lowercased() {
    case "busy": return .busy
    case "free": return .free
    case "tentative": return .tentative
    case "unavailable": return .unavailable
    default: throw bail("bad_param", "availability must be one of busy|free|tentative|unavailable")
    }
}

func priorityLabel(_ p: Int) -> String {
    switch p {
    case 0: return "none"
    case 1...4: return "high"
    case 5: return "medium"
    case 6...9: return "low"
    default: return "none"
    }
}

func priorityValue(_ any: Any) throws -> Int {
    if let n = any as? NSNumber { return max(0, min(9, n.intValue)) }
    if let s = any as? String {
        switch s.lowercased() {
        case "none": return 0
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        default: throw bail("bad_param", "priority must be none|low|medium|high or 0-9")
        }
    }
    throw bail("bad_param", "priority must be none|low|medium|high or 0-9")
}

// MARK: - Recurrence

let weekdayNames: [String: EKWeekday] = [
    "sunday": .sunday, "monday": .monday, "tuesday": .tuesday, "wednesday": .wednesday,
    "thursday": .thursday, "friday": .friday, "saturday": .saturday,
    "sun": .sunday, "mon": .monday, "tue": .tuesday, "wed": .wednesday,
    "thu": .thursday, "fri": .friday, "sat": .saturday
]

func weekdayName(_ w: EKWeekday) -> String {
    switch w {
    case .sunday: return "sunday"
    case .monday: return "monday"
    case .tuesday: return "tuesday"
    case .wednesday: return "wednesday"
    case .thursday: return "thursday"
    case .friday: return "friday"
    case .saturday: return "saturday"
    @unknown default: return "unknown"
    }
}

func frequencyName(_ f: EKRecurrenceFrequency) -> String {
    switch f {
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .monthly: return "monthly"
    case .yearly: return "yearly"
    @unknown default: return "unknown"
    }
}

func serializeRecurrence(_ rules: [EKRecurrenceRule]?) -> [[String: Any]] {
    guard let rules = rules else { return [] }
    return rules.map { rule in
        var out: [String: Any] = [
            "frequency": frequencyName(rule.frequency),
            "interval": rule.interval
        ]
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            out["daysOfTheWeek"] = days.map { d -> [String: Any] in
                var e: [String: Any] = ["day": weekdayName(d.dayOfTheWeek)]
                if d.weekNumber != 0 { e["weekNumber"] = d.weekNumber }
                return e
            }
        }
        if let v = rule.daysOfTheMonth, !v.isEmpty { out["daysOfTheMonth"] = v.map { $0.intValue } }
        if let v = rule.monthsOfTheYear, !v.isEmpty { out["monthsOfTheYear"] = v.map { $0.intValue } }
        if let v = rule.weeksOfTheYear, !v.isEmpty { out["weeksOfTheYear"] = v.map { $0.intValue } }
        if let v = rule.daysOfTheYear, !v.isEmpty { out["daysOfTheYear"] = v.map { $0.intValue } }
        if let v = rule.setPositions, !v.isEmpty { out["setPositions"] = v.map { $0.intValue } }
        if let end = rule.recurrenceEnd {
            if let d = end.endDate {
                out["end"] = ["until": isoString(d) as Any]
            } else if end.occurrenceCount > 0 {
                out["end"] = ["occurrenceCount": end.occurrenceCount]
            }
        }
        return out
    }
}

func parseRecurrence(_ d: [String: Any]) throws -> EKRecurrenceRule {
    let p = Params(raw: d)
    let freqName = (p.string("frequency") ?? "").lowercased()
    let freq: EKRecurrenceFrequency
    switch freqName {
    case "daily": freq = .daily
    case "weekly": freq = .weekly
    case "monthly": freq = .monthly
    case "yearly": freq = .yearly
    default: throw bail("bad_param", "recurrence.frequency must be daily|weekly|monthly|yearly")
    }
    let interval = max(1, p.int("interval") ?? 1)

    var days: [EKRecurrenceDayOfWeek]? = nil
    if let raw = p.anyArray("daysOfTheWeek"), !raw.isEmpty {
        days = try raw.map { item in
            if let s = item as? String {
                guard let w = weekdayNames[s.lowercased()] else {
                    throw bail("bad_param", "Unknown weekday '\(s)'")
                }
                return EKRecurrenceDayOfWeek(w)
            }
            if let obj = item as? [String: Any], let s = obj["day"] as? String {
                guard let w = weekdayNames[s.lowercased()] else {
                    throw bail("bad_param", "Unknown weekday '\(s)'")
                }
                let n = (obj["weekNumber"] as? NSNumber)?.intValue ?? 0
                return EKRecurrenceDayOfWeek(w, weekNumber: n)
            }
            throw bail("bad_param", "daysOfTheWeek entries must be a weekday name or {day, weekNumber}")
        }
    }

    func nums(_ key: String) -> [NSNumber]? {
        guard let arr = p.anyArray(key) as? [NSNumber], !arr.isEmpty else { return nil }
        return arr
    }

    var end: EKRecurrenceEnd? = nil
    if let e = p.dict("end") {
        if let count = (e["occurrenceCount"] as? NSNumber)?.intValue, count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let untilStr = e["until"] as? String {
            end = EKRecurrenceEnd(end: try parseDate(untilStr))
        }
    }

    return EKRecurrenceRule(
        recurrenceWith: freq,
        interval: interval,
        daysOfTheWeek: days,
        daysOfTheMonth: nums("daysOfTheMonth"),
        monthsOfTheYear: nums("monthsOfTheYear"),
        weeksOfTheYear: nums("weeksOfTheYear"),
        daysOfTheYear: nums("daysOfTheYear"),
        setPositions: nums("setPositions"),
        end: end
    )
}

// MARK: - Alarms

func serializeAlarms(_ alarms: [EKAlarm]?) -> [[String: Any]] {
    guard let alarms = alarms else { return [] }
    return alarms.map { a in
        var out: [String: Any] = [:]
        if let abs = a.absoluteDate {
            out["absoluteDate"] = isoString(abs)
        } else {
            out["relativeOffsetMinutes"] = Int(a.relativeOffset / 60)
        }
        if let loc = a.structuredLocation {
            var l: [String: Any] = ["title": loc.title ?? ""]
            if let geo = loc.geoLocation {
                l["latitude"] = geo.coordinate.latitude
                l["longitude"] = geo.coordinate.longitude
            }
            if loc.radius > 0 { l["radius"] = loc.radius }
            l["proximity"] = a.proximity == .enter ? "enter" : (a.proximity == .leave ? "leave" : "none")
            out["location"] = l
        }
        return out
    }
}

func parseAlarm(_ d: [String: Any]) throws -> EKAlarm {
    let p = Params(raw: d)
    let alarm: EKAlarm
    if let absStr = p.string("absoluteDate") {
        alarm = EKAlarm(absoluteDate: try parseDate(absStr))
    } else if let mins = p.int("relativeOffsetMinutes") {
        alarm = EKAlarm(relativeOffset: TimeInterval(mins * 60))
    } else if p.dict("location") != nil {
        alarm = EKAlarm(relativeOffset: 0)
    } else {
        throw bail("bad_param", "Each alarm needs absoluteDate, relativeOffsetMinutes, or location")
    }
    if let l = p.dict("location") {
        let lp = Params(raw: l)
        let loc = EKStructuredLocation(title: lp.string("title") ?? "")
        if let lat = lp.double("latitude"), let lon = lp.double("longitude") {
            loc.geoLocation = CLLocation(latitude: lat, longitude: lon)
        }
        if let r = lp.double("radius") { loc.radius = r }
        alarm.structuredLocation = loc
        switch (lp.string("proximity") ?? "enter").lowercased() {
        case "leave": alarm.proximity = .leave
        case "none": alarm.proximity = .none
        default: alarm.proximity = .enter
        }
    }
    return alarm
}

// MARK: - Bridge

final class Bridge {
    let store = EKEventStore()
    private var eventsGranted = false
    private var remindersGranted = false

    // MARK: Access

    static func statusName(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    /// Reads TCC state without triggering a prompt.
    func accessSnapshot() -> [String: Any] {
        let ev = EKEventStore.authorizationStatus(for: .event)
        let rm = EKEventStore.authorizationStatus(for: .reminder)
        return [
            "events": Bridge.statusName(ev),
            "reminders": Bridge.statusName(rm),
            "eventsUsable": ev == .fullAccess || ev == .authorized,
            "remindersUsable": rm == .fullAccess || rm == .authorized,
            "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        ]
    }

    func requestAccess() -> (events: Bool, reminders: Bool, error: String?) {
        var lastError: String? = nil

        let s1 = DispatchSemaphore(value: 0)
        store.requestFullAccessToEvents { granted, error in
            self.eventsGranted = granted
            if let e = error { lastError = e.localizedDescription }
            s1.signal()
        }
        s1.wait()

        let s2 = DispatchSemaphore(value: 0)
        store.requestFullAccessToReminders { granted, error in
            self.remindersGranted = granted
            if let e = error { lastError = e.localizedDescription }
            s2.signal()
        }
        s2.wait()

        return (eventsGranted, remindersGranted, lastError)
    }

    func ensureEvents() throws {
        let s = EKEventStore.authorizationStatus(for: .event)
        if s == .fullAccess || s == .authorized { eventsGranted = true; return }
        if eventsGranted { return }
        _ = requestAccess()
        guard eventsGranted else {
            throw bail("no_calendar_access",
                       "Calendar access is '\(Bridge.statusName(EKEventStore.authorizationStatus(for: .event)))'. "
                       + "Grant it in System Settings › Privacy & Security › Calendars for the app that launched this server "
                       + "(Claude Code / your terminal), then restart that app. "
                       + "Run `build/ekbridge --request-access` from a normal Terminal window to trigger the prompt.")
        }
    }

    func ensureReminders() throws {
        let s = EKEventStore.authorizationStatus(for: .reminder)
        if s == .fullAccess || s == .authorized { remindersGranted = true; return }
        if remindersGranted { return }
        _ = requestAccess()
        guard remindersGranted else {
            throw bail("no_reminder_access",
                       "Reminders access is '\(Bridge.statusName(EKEventStore.authorizationStatus(for: .reminder)))'. "
                       + "Grant it in System Settings › Privacy & Security › Reminders for the app that launched this server "
                       + "(Claude Code / your terminal), then restart that app. "
                       + "Run `build/ekbridge --request-access` from a normal Terminal window to trigger the prompt.")
        }
    }

    // MARK: Lookup helpers

    func calendar(byId id: String, entity: EKEntityType) throws -> EKCalendar {
        if let c = store.calendar(withIdentifier: id) { return c }
        // fall back to title match, case-insensitive
        let matches = store.calendars(for: entity).filter { $0.title.lowercased() == id.lowercased() }
        if let c = matches.first { return c }
        throw bail("calendar_not_found", "No \(entity == .event ? "calendar" : "reminder list") matching '\(id)'")
    }

    func resolveCalendars(_ ids: [String]?, entity: EKEntityType) throws -> [EKCalendar]? {
        guard let ids = ids, !ids.isEmpty else { return nil }
        return try ids.map { try calendar(byId: $0, entity: entity) }
    }

    func findEvent(id: String, occurrenceDate: Date?) throws -> EKEvent {
        guard let base = store.event(withIdentifier: id) else {
            throw bail("event_not_found", "No event with identifier '\(id)'")
        }
        guard let occ = occurrenceDate else { return base }
        guard let cal = base.calendar else { return base }
        let pred = store.predicateForEvents(withStart: occ.addingTimeInterval(-2 * 86400),
                                            end: occ.addingTimeInterval(2 * 86400),
                                            calendars: [cal])
        let candidates = store.events(matching: pred).filter { $0.eventIdentifier == id }
        let best = candidates.min { a, b in
            let da = abs((a.occurrenceDate ?? a.startDate).timeIntervalSince(occ))
            let db = abs((b.occurrenceDate ?? b.startDate).timeIntervalSince(occ))
            return da < db
        }
        return best ?? base
    }

    func findReminder(id: String) throws -> EKReminder {
        if let item = store.calendarItem(withIdentifier: id) as? EKReminder { return item }
        throw bail("reminder_not_found", "No reminder with identifier '\(id)'")
    }

    func fetchReminders(in calendars: [EKCalendar]?) throws -> [EKReminder] {
        let pred = store.predicateForReminders(in: calendars)
        var result: [EKReminder] = []
        let sem = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: pred) { reminders in
            result = reminders ?? []
            sem.signal()
        }
        if sem.wait(timeout: .now() + 30) == .timedOut {
            throw bail("timeout", "Timed out fetching reminders from EventKit")
        }
        return result
    }

    // MARK: Serialization

    func serializeSource(_ s: EKSource) -> [String: Any] {
        return ["id": s.sourceIdentifier, "title": s.title, "type": sourceTypeName(s.sourceType)]
    }

    func serializeCalendar(_ c: EKCalendar) -> [String: Any] {
        var entities: [String] = []
        if c.allowedEntityTypes.contains(.event) { entities.append("event") }
        if c.allowedEntityTypes.contains(.reminder) { entities.append("reminder") }
        var out: [String: Any] = [
            "id": c.calendarIdentifier,
            "title": c.title,
            "type": calendarTypeName(c.type),
            "entityTypes": entities,
            "writable": c.allowsContentModifications,
            "immutable": c.isImmutable,
            "subscribed": c.isSubscribed
        ]
        if let hex = hexFromCGColor(c.cgColor) { out["color"] = hex }
        out["source"] = serializeSource(c.source)
        return out
    }

    func serializeParticipant(_ p: EKParticipant) -> [String: Any] {
        var out: [String: Any] = [
            "name": p.name ?? "",
            "role": participantRoleName(p.participantRole),
            "status": participantStatusName(p.participantStatus),
            "type": participantTypeName(p.participantType),
            "isMe": p.isCurrentUser
        ]
        let urlString = p.url.absoluteString
        if urlString.lowercased().hasPrefix("mailto:") {
            out["email"] = String(urlString.dropFirst("mailto:".count))
        }
        return out
    }

    func serializeEvent(_ e: EKEvent) -> [String: Any] {
        var out: [String: Any] = [
            "id": e.eventIdentifier ?? "",
            "title": e.title ?? "",
            "allDay": e.isAllDay,
            "status": eventStatusName(e.status),
            "availability": availabilityName(e.availability),
            "isDetached": e.isDetached,
            "hasRecurrence": (e.recurrenceRules?.isEmpty == false)
        ]
        if e.isAllDay {
            out["start"] = dayString(e.startDate)
            out["end"] = dayString(e.endDate)
        } else {
            out["start"] = isoString(e.startDate)
            out["end"] = isoString(e.endDate)
        }
        out["startISO"] = isoString(e.startDate)
        out["endISO"] = isoString(e.endDate)
        if let occ = e.occurrenceDate { out["occurrenceDate"] = isoString(occ) }
        if let n = e.notes, !n.isEmpty { out["notes"] = n }
        if let l = e.location, !l.isEmpty { out["location"] = l }
        if let u = e.url { out["url"] = u.absoluteString }
        if let tz = e.timeZone { out["timeZone"] = tz.identifier }
        if let c = e.calendar {
            out["calendarId"] = c.calendarIdentifier
            out["calendarTitle"] = c.title
            out["calendarWritable"] = c.allowsContentModifications
        }
        let rec = serializeRecurrence(e.recurrenceRules)
        if !rec.isEmpty { out["recurrence"] = rec }
        let alarms = serializeAlarms(e.alarms)
        if !alarms.isEmpty { out["alarms"] = alarms }
        if let att = e.attendees, !att.isEmpty {
            out["attendees"] = att.map { serializeParticipant($0) }
        }
        if let org = e.organizer { out["organizer"] = serializeParticipant(org) }
        if let m = e.lastModifiedDate { out["lastModified"] = isoString(m) }
        if let c = e.creationDate { out["created"] = isoString(c) }
        return out
    }

    func serializeReminder(_ r: EKReminder) -> [String: Any] {
        var out: [String: Any] = [
            "id": r.calendarItemIdentifier,
            "title": r.title ?? "",
            "completed": r.isCompleted,
            "priority": r.priority,
            "priorityLabel": priorityLabel(r.priority)
        ]
        if let d = r.completionDate { out["completionDate"] = isoString(d) }
        if let due = serializeComponents(r.dueDateComponents) { out["due"] = due }
        if let start = serializeComponents(r.startDateComponents) { out["start"] = start }
        if let n = r.notes, !n.isEmpty { out["notes"] = n }
        if let u = r.url { out["url"] = u.absoluteString }
        if let c = r.calendar {
            out["listId"] = c.calendarIdentifier
            out["listTitle"] = c.title
            out["listWritable"] = c.allowsContentModifications
        }
        let rec = serializeRecurrence(r.recurrenceRules)
        if !rec.isEmpty { out["recurrence"] = rec }
        let alarms = serializeAlarms(r.alarms)
        if !alarms.isEmpty { out["alarms"] = alarms }
        if let m = r.lastModifiedDate { out["lastModified"] = isoString(m) }
        if let c = r.creationDate { out["created"] = isoString(c) }
        return out
    }

    // MARK: Mutation helpers

    func applyAlarms(_ p: Params, to item: EKCalendarItem) throws {
        guard p.has("alarms") else { return }
        if let existing = item.alarms {
            for a in existing { item.removeAlarm(a) }
        }
        guard p.present("alarms"), let list = p.array("alarms") else { return }
        for d in list { item.addAlarm(try parseAlarm(d)) }
    }

    func applyRecurrence(_ p: Params, to item: EKCalendarItem) throws {
        guard p.has("recurrence") else { return }
        if let existing = item.recurrenceRules {
            for r in existing { item.removeRecurrenceRule(r) }
        }
        guard p.present("recurrence") else { return }
        if let single = p.dict("recurrence") {
            item.addRecurrenceRule(try parseRecurrence(single))
        } else if let many = p.array("recurrence") {
            for d in many { item.addRecurrenceRule(try parseRecurrence(d)) }
        }
    }

    func spanFrom(_ p: Params) -> EKSpan {
        let s = (p.string("span") ?? "thisEvent").lowercased()
        return (s == "future" || s == "futureevents") ? .futureEvents : .thisEvent
    }

    func requireWritable(_ c: EKCalendar?) throws {
        guard let c = c else { return }
        if !c.allowsContentModifications {
            throw bail("read_only_calendar", "'\(c.title)' is read-only (subscribed or delegated calendars cannot be modified).")
        }
    }

    // MARK: - Dispatch

    func handle(method: String, params raw: [String: Any]) throws -> Any {
        let p = Params(raw: raw)
        // EKEventStore caches aggressively; drop stale state before each command.
        store.reset()

        switch method {

        // ---- meta ----
        case "ping":
            return ["ok": true, "pid": ProcessInfo.processInfo.processIdentifier]

        case "access.status":
            return accessSnapshot()

        case "access.request":
            let r = requestAccess()
            var out = accessSnapshot()
            out["requestedEvents"] = r.events
            out["requestedReminders"] = r.reminders
            if let e = r.error { out["error"] = e }
            return out

        case "sources.list":
            _ = requestAccess()
            return store.sources.map { s -> [String: Any] in
                var out = serializeSource(s)
                out["eventCalendars"] = s.calendars(for: .event).count
                out["reminderLists"] = s.calendars(for: .reminder).count
                return out
            }

        // ---- calendars / lists ----
        case "calendars.list":
            let want = (p.string("entity") ?? "all").lowercased()
            var out: [[String: Any]] = []
            if want == "all" || want == "event" {
                try ensureEvents()
                let def = store.defaultCalendarForNewEvents?.calendarIdentifier
                out += store.calendars(for: .event).map { c -> [String: Any] in
                    var d = serializeCalendar(c)
                    d["entity"] = "event"
                    d["isDefault"] = (c.calendarIdentifier == def)
                    return d
                }
            }
            if want == "all" || want == "reminder" {
                try ensureReminders()
                let def = store.defaultCalendarForNewReminders()?.calendarIdentifier
                out += store.calendars(for: .reminder).map { c -> [String: Any] in
                    var d = serializeCalendar(c)
                    d["entity"] = "reminder"
                    d["isDefault"] = (c.calendarIdentifier == def)
                    return d
                }
            }
            return out

        case "calendars.create":
            let entityName = (p.string("entity") ?? "event").lowercased()
            let entity: EKEntityType = entityName == "reminder" ? .reminder : .event
            entity == .event ? try ensureEvents() : try ensureReminders()
            let title = try p.requiredString("title")

            let cal = EKCalendar(for: entity, eventStore: store)
            cal.title = title
            if let hex = p.string("color") { cal.cgColor = try cgColorFromHex(hex) }

            if let sourceId = p.string("sourceId") {
                guard let src = store.sources.first(where: { $0.sourceIdentifier == sourceId || $0.title == sourceId }) else {
                    throw bail("source_not_found", "No account/source matching '\(sourceId)'")
                }
                cal.source = src
            } else {
                // Prefer the source that already owns the default calendar, else iCloud, else local.
                let fallback = entity == .event
                    ? store.defaultCalendarForNewEvents?.source
                    : store.defaultCalendarForNewReminders()?.source
                if let f = fallback {
                    cal.source = f
                } else if let icloud = store.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" }) {
                    cal.source = icloud
                } else if let local = store.sources.first(where: { $0.sourceType == .local }) {
                    cal.source = local
                } else {
                    throw bail("no_source", "No writable account found to create the calendar in")
                }
            }
            try store.saveCalendar(cal, commit: true)
            return serializeCalendar(cal)

        case "calendars.update":
            let entityName = (p.string("entity") ?? "event").lowercased()
            let entity: EKEntityType = entityName == "reminder" ? .reminder : .event
            entity == .event ? try ensureEvents() : try ensureReminders()
            let cal = try calendar(byId: try p.requiredString("id"), entity: entity)
            try requireWritable(cal)
            if let t = p.string("title") { cal.title = t }
            if let hex = p.string("color") { cal.cgColor = try cgColorFromHex(hex) }
            try store.saveCalendar(cal, commit: true)
            return serializeCalendar(cal)

        case "calendars.delete":
            let entityName = (p.string("entity") ?? "event").lowercased()
            let entity: EKEntityType = entityName == "reminder" ? .reminder : .event
            entity == .event ? try ensureEvents() : try ensureReminders()
            let cal = try calendar(byId: try p.requiredString("id"), entity: entity)
            var snapshot = serializeCalendar(cal)
            if cal.isImmutable {
                throw bail("read_only_calendar", "'\(cal.title)' cannot be deleted.")
            }
            // Count what goes with it, so a preview is actually informative.
            if entity == .event {
                let now = Date()
                let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-365 * 86400),
                                                    end: now.addingTimeInterval(365 * 86400),
                                                    calendars: [cal])
                snapshot["eventsWithinOneYear"] = store.events(matching: pred).count
            } else {
                snapshot["reminderCount"] = (try? fetchReminders(in: [cal]).count) ?? -1
            }
            let dryRun = p.bool("dryRun", default: true)
            if !dryRun {
                try store.removeCalendar(cal, commit: true)
            }
            return ["dryRun": dryRun, "matched": snapshot]

        // ---- events ----
        case "events.list", "events.search":
            try ensureEvents()
            let start = try p.requiredDate("start")
            let end = try p.requiredDate("end")
            guard end > start else { throw bail("bad_range", "'end' must be after 'start'") }
            let cals = try resolveCalendars(p.stringArray("calendarIds"), entity: .event)
            let pred = store.predicateForEvents(withStart: start, end: end, calendars: cals)
            var events = store.events(matching: pred)

            if let q = p.string("query"), !q.isEmpty {
                let needle = q.lowercased()
                events = events.filter {
                    ($0.title ?? "").lowercased().contains(needle)
                        || ($0.notes ?? "").lowercased().contains(needle)
                        || ($0.location ?? "").lowercased().contains(needle)
                }
            }
            if !p.bool("includeCanceled", default: false) {
                events = events.filter { $0.status != .canceled }
            }
            events.sort { $0.startDate < $1.startDate }
            let limit = p.int("limit") ?? 200
            let total = events.count
            if events.count > limit { events = Array(events.prefix(limit)) }
            return ["total": total, "returned": events.count, "truncated": total > events.count,
                    "events": events.map { serializeEvent($0) }]

        case "events.get":
            try ensureEvents()
            let e = try findEvent(id: try p.requiredString("id"), occurrenceDate: try p.date("occurrenceDate"))
            return serializeEvent(e)

        case "events.create":
            try ensureEvents()
            let e = EKEvent(eventStore: store)
            e.title = try p.requiredString("title")

            if let calId = p.string("calendarId") {
                e.calendar = try calendar(byId: calId, entity: .event)
            } else {
                guard let def = store.defaultCalendarForNewEvents else {
                    throw bail("no_default_calendar", "No default calendar for new events; pass calendarId.")
                }
                e.calendar = def
            }
            try requireWritable(e.calendar)

            let startStr = try p.requiredString("start")
            let allDay = p.optBool("allDay") ?? isDateOnly(startStr)
            e.isAllDay = allDay
            e.startDate = try parseDate(startStr)
            if let endStr = p.string("end") {
                e.endDate = try parseDate(endStr)
            } else if let mins = p.int("durationMinutes") {
                e.endDate = e.startDate.addingTimeInterval(TimeInterval(mins * 60))
            } else {
                e.endDate = e.startDate.addingTimeInterval(allDay ? 0 : 3600)
            }
            guard e.endDate >= e.startDate else { throw bail("bad_range", "'end' must not be before 'start'") }

            if let n = p.string("notes") { e.notes = n }
            if let l = p.string("location") { e.location = l }
            if let u = p.string("url") { e.url = URL(string: u) }
            if let tz = p.string("timeZone") { e.timeZone = TimeZone(identifier: tz) }
            if let a = p.string("availability") { e.availability = try availabilityFromName(a) }
            try applyRecurrence(p, to: e)
            try applyAlarms(p, to: e)

            try store.save(e, span: .futureEvents, commit: true)
            return serializeEvent(e)

        case "events.update":
            try ensureEvents()
            let e = try findEvent(id: try p.requiredString("id"), occurrenceDate: try p.date("occurrenceDate"))
            try requireWritable(e.calendar)

            if let t = p.string("title") { e.title = t }
            if p.has("notes") { e.notes = p.string("notes") }
            if p.has("location") { e.location = p.string("location") }
            if p.has("url") { e.url = p.string("url").flatMap { URL(string: $0) } }
            if let tz = p.string("timeZone") { e.timeZone = TimeZone(identifier: tz) }
            if let a = p.string("availability") { e.availability = try availabilityFromName(a) }
            if let calId = p.string("calendarId") {
                let target = try calendar(byId: calId, entity: .event)
                try requireWritable(target)
                e.calendar = target
            }

            if let allDay = p.optBool("allDay") { e.isAllDay = allDay }
            if let startStr = p.string("start") {
                if p.optBool("allDay") == nil && isDateOnly(startStr) { e.isAllDay = true }
                let oldDuration = e.endDate.timeIntervalSince(e.startDate)
                e.startDate = try parseDate(startStr)
                if p.string("end") == nil && p.int("durationMinutes") == nil {
                    e.endDate = e.startDate.addingTimeInterval(oldDuration)
                }
            }
            if let endStr = p.string("end") {
                e.endDate = try parseDate(endStr)
            } else if let mins = p.int("durationMinutes") {
                e.endDate = e.startDate.addingTimeInterval(TimeInterval(mins * 60))
            }
            guard e.endDate >= e.startDate else { throw bail("bad_range", "'end' must not be before 'start'") }

            try applyRecurrence(p, to: e)
            try applyAlarms(p, to: e)

            try store.save(e, span: spanFrom(p), commit: true)
            return serializeEvent(e)

        case "events.delete":
            try ensureEvents()
            let ids = try p.stringArray("ids") ?? [p.requiredString("id")]
            let occurrences = p.stringArray("occurrenceDates")
            let span = spanFrom(p)
            let dryRun = p.bool("dryRun", default: true)

            var affected: [[String: Any]] = []
            var failures: [[String: Any]] = []
            for (i, id) in ids.enumerated() {
                do {
                    let occ = (occurrences != nil && i < occurrences!.count) ? try parseDate(occurrences![i]) : nil
                    let e = try findEvent(id: id, occurrenceDate: occ)
                    affected.append(serializeEvent(e))
                    if !dryRun {
                        try requireWritable(e.calendar)
                        try store.remove(e, span: span, commit: true)
                    }
                } catch let err as BridgeError {
                    failures.append(["id": id, "code": err.code, "message": err.message])
                } catch {
                    failures.append(["id": id, "code": "unknown", "message": error.localizedDescription])
                }
            }
            return ["dryRun": dryRun, "span": span == .futureEvents ? "future" : "thisEvent",
                    "count": affected.count, "matched": affected, "failures": failures]

        case "events.freeTime":
            try ensureEvents()
            let start = try p.requiredDate("start")
            let end = try p.requiredDate("end")
            guard end > start else { throw bail("bad_range", "'end' must be after 'start'") }
            let duration = TimeInterval((p.int("durationMinutes") ?? 30) * 60)
            let cals = try resolveCalendars(p.stringArray("calendarIds"), entity: .event)
            let dayStartMin = p.int("dayStartMinutes") ?? (9 * 60)
            let dayEndMin = p.int("dayEndMinutes") ?? (18 * 60)
            let weekdaysOnly = p.bool("weekdaysOnly", default: true)
            let maxSlots = p.int("maxSlots") ?? 20

            let pred = store.predicateForEvents(withStart: start, end: end, calendars: cals)
            var busy: [(Date, Date)] = store.events(matching: pred)
                .filter { $0.status != .canceled && $0.availability != .free }
                .map { ($0.startDate, $0.endDate) }
                .sorted { $0.0 < $1.0 }

            // merge overlapping busy blocks
            var merged: [(Date, Date)] = []
            for b in busy {
                if var last = merged.last, b.0 <= last.1 {
                    last.1 = max(last.1, b.1)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(b)
                }
            }
            busy = merged

            var slots: [[String: Any]] = []
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            var cursorDay = cal.startOfDay(for: start)
            let lastDay = cal.startOfDay(for: end)

            while cursorDay <= lastDay && slots.count < maxSlots {
                let weekday = cal.component(.weekday, from: cursorDay) // 1 = Sunday
                let isWeekend = (weekday == 1 || weekday == 7)
                if !(weekdaysOnly && isWeekend) {
                    let windowStart = max(cursorDay.addingTimeInterval(TimeInterval(dayStartMin * 60)), start)
                    let windowEnd = min(cursorDay.addingTimeInterval(TimeInterval(dayEndMin * 60)), end)
                    if windowEnd > windowStart {
                        var cursor = windowStart
                        for b in busy where b.1 > windowStart && b.0 < windowEnd {
                            if b.0.timeIntervalSince(cursor) >= duration {
                                slots.append(["start": isoString(cursor) as Any, "end": isoString(b.0) as Any,
                                              "minutes": Int(b.0.timeIntervalSince(cursor) / 60)])
                                if slots.count >= maxSlots { break }
                            }
                            cursor = max(cursor, b.1)
                        }
                        if slots.count < maxSlots && windowEnd.timeIntervalSince(cursor) >= duration {
                            slots.append(["start": isoString(cursor) as Any, "end": isoString(windowEnd) as Any,
                                          "minutes": Int(windowEnd.timeIntervalSince(cursor) / 60)])
                        }
                    }
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: cursorDay) else { break }
                cursorDay = next
            }
            return ["durationMinutes": Int(duration / 60), "busyBlocks": busy.count, "slots": slots]

        // ---- reminders ----
        case "reminders.list", "reminders.search":
            try ensureReminders()
            let cals = try resolveCalendars(p.stringArray("listIds"), entity: .reminder)
            var items = try fetchReminders(in: cals)

            let status = (p.string("status") ?? "incomplete").lowercased()
            if status == "incomplete" { items = items.filter { !$0.isCompleted } }
            else if status == "completed" { items = items.filter { $0.isCompleted } }

            if let q = p.string("query"), !q.isEmpty {
                let needle = q.lowercased()
                items = items.filter {
                    ($0.title ?? "").lowercased().contains(needle) || ($0.notes ?? "").lowercased().contains(needle)
                }
            }

            let dueStart = try p.date("dueStart")
            let dueEnd = try p.date("dueEnd")
            let onlyDated = p.bool("onlyWithDueDate", default: false)
            if dueStart != nil || dueEnd != nil || onlyDated {
                items = items.filter { r in
                    guard let comps = r.dueDateComponents, let d = Calendar.current.date(from: comps) else {
                        return false
                    }
                    if let s = dueStart, d < s { return false }
                    if let e = dueEnd, d > e { return false }
                    return true
                }
            }

            items.sort { a, b in
                let da = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantFuture
                let db = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantFuture
                if da != db { return da < db }
                return (a.title ?? "") < (b.title ?? "")
            }

            let limit = p.int("limit") ?? 200
            let total = items.count
            if items.count > limit { items = Array(items.prefix(limit)) }
            return ["total": total, "returned": items.count, "truncated": total > items.count,
                    "reminders": items.map { serializeReminder($0) }]

        case "reminders.get":
            try ensureReminders()
            return serializeReminder(try findReminder(id: try p.requiredString("id")))

        case "reminders.create":
            try ensureReminders()
            let r = EKReminder(eventStore: store)
            r.title = try p.requiredString("title")

            if let listId = p.string("listId") {
                r.calendar = try calendar(byId: listId, entity: .reminder)
            } else {
                guard let def = store.defaultCalendarForNewReminders() else {
                    throw bail("no_default_list", "No default reminder list; pass listId.")
                }
                r.calendar = def
            }
            try requireWritable(r.calendar)

            if let n = p.string("notes") { r.notes = n }
            if let u = p.string("url") { r.url = URL(string: u) }
            if let prio = raw["priority"] { r.priority = try priorityValue(prio) }

            let tz = p.string("timeZone").flatMap { TimeZone(identifier: $0) }
            var dueDate: Date? = nil
            if let dueStr = p.string("due") {
                let d = try parseDate(dueStr)
                dueDate = d
                r.dueDateComponents = components(from: d, dateOnly: isDateOnly(dueStr), timeZone: tz)
            }
            if let startStr = p.string("start") {
                let d = try parseDate(startStr)
                r.startDateComponents = components(from: d, dateOnly: isDateOnly(startStr), timeZone: tz)
            }

            try applyRecurrence(p, to: r)
            try applyAlarms(p, to: r)

            // EventKit does not auto-alert on a timed due date; opt in explicitly.
            if p.bool("remindAtDueTime", default: false), let d = dueDate, (r.alarms?.isEmpty ?? true) {
                r.addAlarm(EKAlarm(absoluteDate: d))
            }
            if p.bool("completed", default: false) { r.isCompleted = true }

            try store.save(r, commit: true)
            return serializeReminder(r)

        case "reminders.update":
            try ensureReminders()
            let r = try findReminder(id: try p.requiredString("id"))
            try requireWritable(r.calendar)

            if let t = p.string("title") { r.title = t }
            if p.has("notes") { r.notes = p.string("notes") }
            if p.has("url") { r.url = p.string("url").flatMap { URL(string: $0) } }
            if p.present("priority"), let prio = raw["priority"] { r.priority = try priorityValue(prio) }
            if let listId = p.string("listId") {
                let target = try calendar(byId: listId, entity: .reminder)
                try requireWritable(target)
                r.calendar = target
            }

            let tz = p.string("timeZone").flatMap { TimeZone(identifier: $0) }
            var dueDate: Date? = nil
            if p.has("due") {
                if let dueStr = p.string("due") {
                    let d = try parseDate(dueStr)
                    dueDate = d
                    r.dueDateComponents = components(from: d, dateOnly: isDateOnly(dueStr), timeZone: tz)
                } else {
                    r.dueDateComponents = nil
                }
            }
            if p.has("start") {
                if let startStr = p.string("start") {
                    let d = try parseDate(startStr)
                    r.startDateComponents = components(from: d, dateOnly: isDateOnly(startStr), timeZone: tz)
                } else {
                    r.startDateComponents = nil
                }
            }

            try applyRecurrence(p, to: r)
            try applyAlarms(p, to: r)

            if p.bool("remindAtDueTime", default: false), let d = dueDate, (r.alarms?.isEmpty ?? true) {
                r.addAlarm(EKAlarm(absoluteDate: d))
            }
            if let done = p.optBool("completed") {
                r.isCompleted = done
                if !done { r.completionDate = nil }
            }

            try store.save(r, commit: true)
            return serializeReminder(r)

        case "reminders.delete":
            try ensureReminders()
            let ids = try p.stringArray("ids") ?? [p.requiredString("id")]
            let dryRun = p.bool("dryRun", default: true)
            var affected: [[String: Any]] = []
            var failures: [[String: Any]] = []
            for id in ids {
                do {
                    let r = try findReminder(id: id)
                    affected.append(serializeReminder(r))
                    if !dryRun {
                        try requireWritable(r.calendar)
                        try store.remove(r, commit: true)
                    }
                } catch let err as BridgeError {
                    failures.append(["id": id, "code": err.code, "message": err.message])
                } catch {
                    failures.append(["id": id, "code": "unknown", "message": error.localizedDescription])
                }
            }
            return ["dryRun": dryRun, "count": affected.count, "matched": affected, "failures": failures]

        case "reminders.complete":
            try ensureReminders()
            let ids = try p.stringArray("ids") ?? [p.requiredString("id")]
            let done = p.bool("completed", default: true)
            var updated: [[String: Any]] = []
            var failures: [[String: Any]] = []
            for id in ids {
                do {
                    let r = try findReminder(id: id)
                    try requireWritable(r.calendar)
                    r.isCompleted = done
                    if !done { r.completionDate = nil }
                    try store.save(r, commit: true)
                    updated.append(serializeReminder(r))
                } catch let err as BridgeError {
                    failures.append(["id": id, "code": err.code, "message": err.message])
                } catch {
                    failures.append(["id": id, "code": "unknown", "message": error.localizedDescription])
                }
            }
            return ["completed": done, "count": updated.count, "reminders": updated, "failures": failures]

        default:
            throw bail("unknown_method", "Unknown method '\(method)'")
        }
    }
}

// MARK: - IO

func writeLine(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
        FileHandle.standardOutput.write(
            "{\"ok\":false,\"error\":{\"code\":\"serialize_failed\",\"message\":\"unserializable result\"}}\n".data(using: .utf8)!)
        return
    }
    var out = data
    out.append(0x0A)
    FileHandle.standardOutput.write(out)
}

func errorPayload(_ error: Error) -> [String: Any] {
    if let b = error as? BridgeError {
        return ["code": b.code, "message": b.message]
    }
    let ns = error as NSError
    return ["code": "eventkit_error_\(ns.code)", "message": ns.localizedDescription]
}

@main
struct EKBridgeMain {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        let bridge = Bridge()

        if args.first == "--request-access" {
            let r = bridge.requestAccess()
            writeLine(["ok": true, "result": ["events": r.events, "reminders": r.reminders, "error": r.error as Any]])
            exit(r.events && r.reminders ? 0 : 1)
        }

        if let method = args.first, method != "--serve" {
            let jsonText = args.count > 1 ? args[1] : "{}"
            let params = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any] ?? [:]
            do {
                let result = try bridge.handle(method: method, params: params)
                writeLine(["ok": true, "result": result])
                exit(0)
            } catch {
                writeLine(["ok": false, "error": errorPayload(error)])
                exit(1)
            }
        }

        // serve mode: read stdin on a worker thread so the main run loop stays free
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                var requestId: Any = NSNull()
                do {
                    guard let obj = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                        throw bail("bad_request", "Request must be a JSON object")
                    }
                    if let rid = obj["id"] { requestId = rid }
                    guard let method = obj["method"] as? String else {
                        throw bail("bad_request", "Request needs a 'method' string")
                    }
                    let params = obj["params"] as? [String: Any] ?? [:]
                    let result = try bridge.handle(method: method, params: params)
                    writeLine(["id": requestId, "ok": true, "result": result])
                } catch {
                    writeLine(["id": requestId, "ok": false, "error": errorPayload(error)])
                }
            }
            exit(0)
        }

        RunLoop.main.run()
    }
}

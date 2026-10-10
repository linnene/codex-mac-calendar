import CoreLocation
import EventKit
import Foundation

// MARK: - Event support

extension Store {

    // MARK: Recurrence rules

    static func weekday(_ value: String) -> EKWeekday? {
        switch value.lowercased() {
        case "su", "sun", "sunday", "日", "周日", "星期日", "星期天": return .sunday
        case "mo", "mon", "monday", "一", "周一", "星期一": return .monday
        case "tu", "tue", "tues", "tuesday", "二", "周二", "星期二": return .tuesday
        case "we", "wed", "wednesday", "三", "周三", "星期三": return .wednesday
        case "th", "thu", "thur", "thurs", "thursday", "四", "周四", "星期四": return .thursday
        case "fr", "fri", "friday", "五", "周五", "星期五": return .friday
        case "sa", "sat", "saturday", "六", "周六", "星期六": return .saturday
        default: return nil
        }
    }

    static func weekdayName(_ weekday: EKWeekday) -> String {
        switch weekday {
        case .sunday: return "sun"
        case .monday: return "mon"
        case .tuesday: return "tue"
        case .wednesday: return "wed"
        case .thursday: return "thu"
        case .friday: return "fri"
        case .saturday: return "sat"
        @unknown default: return "unknown"
        }
    }

    static func frequencyName(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "unknown"
        }
    }

    static func frequency(_ value: String) throws -> EKRecurrenceFrequency {
        switch value.lowercased() {
        case "daily", "day", "每天", "日": return .daily
        case "weekly", "week", "每周", "周": return .weekly
        case "monthly", "month", "每月", "月": return .monthly
        case "yearly", "annual", "year", "每年", "年": return .yearly
        default:
            throw BridgeError.invalid(
                "Unknown recurrence frequency '\(value)'.",
                "Use daily, weekly, monthly, or yearly."
            )
        }
    }

    func recurrenceDict(_ rule: EKRecurrenceRule) -> [String: Any] {
        var entry: [String: Any] = [
            "frequency": Self.frequencyName(rule.frequency),
            "interval": rule.interval,
        ]
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            entry["daysOfWeek"] = days.map { day -> String in
                let name = Self.weekdayName(day.dayOfTheWeek)
                return day.weekNumber == 0 ? name : "\(name)#\(day.weekNumber)"
            }
        }
        if let days = rule.daysOfTheMonth, !days.isEmpty { entry["daysOfMonth"] = days.map(\.intValue) }
        if let months = rule.monthsOfTheYear, !months.isEmpty { entry["monthsOfYear"] = months.map(\.intValue) }
        if let weeks = rule.weeksOfTheYear, !weeks.isEmpty { entry["weeksOfTheYear"] = weeks.map(\.intValue) }
        if let days = rule.daysOfTheYear, !days.isEmpty { entry["daysOfTheYear"] = days.map(\.intValue) }
        if let positions = rule.setPositions, !positions.isEmpty { entry["setPositions"] = positions.map(\.intValue) }
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                entry["count"] = end.occurrenceCount
            } else if let endDate = end.endDate {
                entry["until"] = Dates.iso(endDate, timeZone: timeZone)
            }
        }
        entry["summary"] = Self.describeRecurrence(entry)
        return entry
    }

    static func describeRecurrence(_ entry: [String: Any]) -> String {
        let interval = (entry["interval"] as? Int) ?? 1
        let frequency = (entry["frequency"] as? String) ?? "daily"
        let unit: String
        switch frequency {
        case "daily": unit = "day"
        case "weekly": unit = "week"
        case "monthly": unit = "month"
        default: unit = "year"
        }
        var text = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
        if let days = entry["daysOfWeek"] as? [String], !days.isEmpty {
            text += " on \(days.joined(separator: ", "))"
        }
        if let days = entry["daysOfMonth"] as? [Int], !days.isEmpty {
            text += " on day \(days.map(String.init).joined(separator: ", "))"
        }
        if let count = entry["count"] as? Int { text += ", \(count) times" }
        if let until = entry["until"] as? String { text += ", until \(until)" }
        return text
    }

    func recurrenceRules(_ specs: [Args]) throws -> [EKRecurrenceRule] {
        try specs.map { spec in
            let frequency = try Self.frequency(spec.string("frequency") ?? spec.string("freq") ?? "weekly")
            let interval = max(1, spec.intOr("interval", 1))

            var daysOfWeek: [EKRecurrenceDayOfWeek]?
            let daySpecs = spec.strings("days_of_week") + spec.strings("daysOfWeek")
            if !daySpecs.isEmpty {
                daysOfWeek = try daySpecs.map { raw in
                    let parts = raw.split(separator: "#")
                    guard let weekday = Self.weekday(String(parts[0])) else {
                        throw BridgeError.invalid(
                            "Unknown weekday '\(raw)'.",
                            "Use su, mo, tu, we, th, fr, sa."
                        )
                    }
                    let weekNumber = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                    if frequency != .weekly && frequency != .monthly && weekNumber != 0 {
                        throw BridgeError.invalid(
                            "Week numbers are only valid for weekly or monthly recurrences.",
                            nil
                        )
                    }
                    return EKRecurrenceDayOfWeek(weekday, weekNumber: weekNumber)
                }
            }

            var end: EKRecurrenceEnd?
            if let count = spec.int("count") {
                guard count > 0 else {
                    throw BridgeError.invalid("Recurrence 'count' must be positive.", nil)
                }
                end = EKRecurrenceEnd(occurrenceCount: count)
            } else if let untilText = spec.string("until") {
                let until = try Dates.parse(untilText, timeZone: timeZone).date
                end = EKRecurrenceEnd(end: until)
            }

            let numbers = { (key: String) -> [NSNumber]? in
                let values = spec.strings(key).compactMap { Int($0) } + spec.array(key).compactMap { ($0 as? NSNumber)?.intValue }
                return values.isEmpty ? nil : values.map { NSNumber(value: $0) }
            }

            return EKRecurrenceRule(
                recurrenceWith: frequency,
                interval: interval,
                daysOfTheWeek: daysOfWeek,
                daysOfTheMonth: numbers("days_of_month"),
                monthsOfTheYear: numbers("months_of_year"),
                weeksOfTheYear: numbers("weeks_of_year"),
                daysOfTheYear: numbers("days_of_year"),
                setPositions: numbers("set_positions"),
                end: end
            )
        }
    }

    // MARK: Alarms

    func alarmDict(_ alarm: EKAlarm) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let absolute = alarm.absoluteDate {
            entry["kind"] = "absolute"
            entry["at"] = Dates.iso(absolute, timeZone: timeZone)
            entry["atLocal"] = Dates.local(absolute, timeZone: timeZone)
        } else if alarm.relativeOffset != 0 || alarm.structuredLocation == nil {
            entry["kind"] = "relative"
            entry["minutesBefore"] = Int(-alarm.relativeOffset / 60)
            entry["offsetSeconds"] = Int(alarm.relativeOffset)
            entry["offsetDescription"] = Dates.describeOffset(alarm.relativeOffset)
        }
        if let location = alarm.structuredLocation {
            var locationEntry: [String: Any] = ["title": location.title ?? ""]
            if let geo = location.geoLocation {
                locationEntry["latitude"] = geo.coordinate.latitude
                locationEntry["longitude"] = geo.coordinate.longitude
            }
            locationEntry["radius"] = location.radius
            switch alarm.proximity {
            case .enter: locationEntry["on"] = "enter"
            case .leave: locationEntry["on"] = "leave"
            default: locationEntry["on"] = "none"
            }
            entry["kind"] = "location"
            entry["location"] = locationEntry
        }
        if let sound = alarm.soundName { entry["sound"] = sound }
        return entry
    }

    func alarm(_ spec: Args) throws -> EKAlarm {
        if let locationSpec = spec.object("location") {
            let title = locationSpec.string("title") ?? locationSpec.string("name") ?? ""
            let location = EKStructuredLocation(title: title)
            if let latitude = locationSpec.double("latitude"), let longitude = locationSpec.double("longitude") {
                location.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
            }
            location.radius = locationSpec.double("radius") ?? 100
            let alarm = EKAlarm()
            alarm.structuredLocation = location
            alarm.proximity = try Self.proximity(from: locationSpec.string("on") ?? "enter")
            return alarm
        }
        if let at = spec.string("at") ?? spec.string("absolute") {
            let date = try Dates.parse(at, timeZone: timeZone).date
            return EKAlarm(absoluteDate: date)
        }
        if let minutesBefore = spec.double("minutes_before") ?? spec.double("minutesBefore") {
            return EKAlarm(relativeOffset: -minutesBefore * 60)
        }
        if let minutesAfter = spec.double("minutes_after") ?? spec.double("minutesAfter") {
            return EKAlarm(relativeOffset: minutesAfter * 60)
        }
        if let seconds = spec.double("offset_seconds") {
            return EKAlarm(relativeOffset: seconds)
        }
        // Default: 15 minutes before, matching Calendar.app's own default.
        if spec.has("default") {
            return EKAlarm(relativeOffset: -900)
        }
        throw BridgeError.invalid(
            "An alarm needs 'minutes_before' (or minutesBefore / minutes_after / at / location).",
            "Example: {\"minutes_before\": 15} or {\"at\": \"2026-10-10T09:00:00+08:00\"}."
        )
    }

    func alarms(_ specs: [Args]) throws -> [EKAlarm] {
        try specs.map { try alarm($0) }
    }

    // MARK: All-day handling

    /// All-day events are stored with an *inclusive* end at 23:59:59 on the last
    /// day — EventKit snaps whatever end date it is given to the end of the day it
    /// falls in. Some servers hand back an exclusive midnight instead, so both
    /// shapes are normalised to the last included calendar day here.
    func allDaySpan(start: Date, end: Date, calendar: Calendar) -> (startDay: Date, lastDay: Date, days: Int) {
        let startDay = calendar.startOfDay(for: start)
        var last = end
        if calendar.startOfDay(for: last) == last, last > startDay {
            last = last.addingTimeInterval(-1)
        }
        let lastDay = max(startDay, calendar.startOfDay(for: last))
        let days = (calendar.dateComponents([.day], from: startDay, to: lastDay).day ?? 0) + 1
        return (startDay, lastDay, max(1, days))
    }

    func allDaySpan(_ event: EKEvent, zone: TimeZone) -> (startDay: Date, lastDay: Date, days: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return allDaySpan(start: event.safeStart, end: event.safeEnd, calendar: calendar)
    }

    /// End moment EventKit expects for an all-day event covering `days` days from
    /// `startDay`: the last second of the final day.
    func allDayEnd(from startDay: Date, days: Int, calendar: Calendar) -> Date {
        let afterLast = calendar.date(byAdding: .day, value: max(1, days), to: startDay) ?? startDay.addingTimeInterval(86_400)
        return afterLast.addingTimeInterval(-1)
    }

    // MARK: Event serialisation

    func eventDict(_ event: EKEvent, includeDetails: Bool = true) -> [String: Any] {
        let start = event.safeStart
        let end = event.safeEnd
        let occurrence = event.safeOccurrence

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var entry: [String: Any] = [
            "id": event.safeIdentifier,
            "title": event.title ?? "",
            "calendar": event.calendar.title,
            "calendarId": event.calendar.calendarIdentifier,
            "account": event.calendar.source.title,
            "start": Dates.iso(start, timeZone: timeZone),
            "end": Dates.iso(end, timeZone: timeZone),
            "allDay": event.isAllDay,
            "availability": Self.availabilityName(event.availability),
            "status": Self.statusName(event.status),
            "isRecurring": event.hasRecurrenceRules,
            "isDetached": event.isDetached,
        ]

        if event.isAllDay {
            // For an all-day event the stored end is the last second of the final
            // day, so the useful facts are the inclusive date range and the day
            // count. Reporting a 1439-minute "duration" for a one-day event would
            // only be confusing.
            let span = allDaySpan(start: start, end: end, calendar: calendar)
            entry["startDate"] = Dates.dateOnly(span.startDay, timeZone: timeZone)
            entry["endDate"] = Dates.dateOnly(span.lastDay, timeZone: timeZone)
            entry["startLocal"] = Dates.dateOnly(span.startDay, timeZone: timeZone)
            entry["endLocal"] = Dates.dateOnly(span.lastDay, timeZone: timeZone)
            entry["durationDays"] = span.days
            entry["durationMinutes"] = span.days * 1_440
            entry["endIsInclusiveLastDay"] = true
        } else {
            entry["startLocal"] = Dates.local(start, timeZone: timeZone)
            entry["endLocal"] = Dates.local(end, timeZone: timeZone)
            entry["durationMinutes"] = Int(end.timeIntervalSince(start) / 60)
        }
        if let hex = Colors.hex(event.calendar.color) {
            entry["colorHex"] = hex
        } else {
            entry["colorHex"] = NSNull()
        }
        if let occurrence { entry["occurrenceDate"] = Dates.iso(occurrence, timeZone: timeZone) }
        if let zone = event.timeZone { entry["eventTimeZone"] = zone.identifier }

        guard includeDetails else { return entry }

        if let location = clean(event.location) { entry["location"] = location }
        let (notes, notesTruncated) = truncateBody(event.notes, label: "notes")
        if let notes { entry["notes"] = notes }
        if notesTruncated { entry["notesTruncated"] = true }
        if let url = event.url { entry["url"] = url.absoluteString }
        if let organizer = event.organizer {
            entry["organizer"] = participantDict(organizer)
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            entry["attendees"] = attendees.map(participantDict)
            entry["attendeeCount"] = attendees.count
        }
        if let rules = event.recurrenceRules, !rules.isEmpty {
            entry["recurrence"] = rules.map(recurrenceDict)
        }
        if let alarms = event.alarms, !alarms.isEmpty {
            entry["alarms"] = alarms.map(alarmDict)
        }
        if let created = event.creationDate { entry["created"] = Dates.iso(created, timeZone: timeZone) }
        if let modified = event.lastModifiedDate { entry["lastModified"] = Dates.iso(modified, timeZone: timeZone) }
        entry["writable"] = event.calendar.allowsContentModifications
            && !event.calendar.isImmutable
            && !event.calendar.isSubscribed
        return entry
    }

    func participantDict(_ participant: EKParticipant) -> [String: Any] {
        var entry: [String: Any] = [
            "name": participant.name ?? "",
            "url": participant.url.absoluteString,
            "isCurrentUser": participant.isCurrentUser,
        ]
        switch participant.participantStatus {
        case .accepted: entry["status"] = "accepted"
        case .declined: entry["status"] = "declined"
        case .tentative: entry["status"] = "tentative"
        case .pending: entry["status"] = "pending"
        case .delegated: entry["status"] = "delegated"
        case .completed: entry["status"] = "completed"
        case .inProcess: entry["status"] = "inProcess"
        default: entry["status"] = "unknown"
        }
        switch participant.participantRole {
        case .required: entry["role"] = "required"
        case .optional: entry["role"] = "optional"
        case .chair: entry["role"] = "chair"
        case .nonParticipant: entry["role"] = "nonParticipant"
        default: entry["role"] = "unknown"
        }
        switch participant.participantType {
        case .person: entry["type"] = "person"
        case .room: entry["type"] = "room"
        case .resource: entry["type"] = "resource"
        case .group: entry["type"] = "group"
        default: entry["type"] = "unknown"
        }
        return entry
    }

    // MARK: Event lookup

    func resolveCalendars(_ args: Args, entity: EKEntityType) throws -> [EKCalendar]? {
        var requested: [String] = []
        if entity == .event {
            requested.append(contentsOf: args.strings("calendar_ids"))
            requested.append(contentsOf: args.strings("calendarIds"))
            if let single = args.string("calendar_id") ?? args.string("calendarId") { requested.append(single) }
            requested.append(contentsOf: args.strings("calendars"))
        } else {
            requested.append(contentsOf: args.strings("list_ids"))
            requested.append(contentsOf: args.strings("listIds"))
            if let single = args.string("list_id") ?? args.string("listId") { requested.append(single) }
        }
        // Both naming conventions are accepted for either entity so a caller can
        // pass `lists` to a reminder tool and `calendars` to an event tool.
        requested.append(contentsOf: args.strings("lists"))
        requested.append(contentsOf: args.strings("calendars"))
        if let single = args.string("calendar") { requested.append(single) }
        if let single = args.string("list") { requested.append(single) }

        guard !requested.isEmpty else { return nil }
        if requested.contains(where: { $0.lowercased() == "all" || $0 == "*" }) { return nil }

        return try requested.map { value in
            try resolveTarget(value, entity: entity)
        }
    }

    func resolveEvent(id: String, occurrenceDate: Date?) throws -> EKEvent {
        guard let base = store.event(withIdentifier: id) else {
            throw BridgeError.notFound(
                "No event with id '\(id)'.",
                "Ids come from calendar_list_events. Recurring series share one id across occurrences; pass occurrence_date to target a specific occurrence."
            )
        }
        guard let target = occurrenceDate, base.hasRecurrenceRules else { return base }

        let windowStart = target.addingTimeInterval(-86_400 * 2)
        let windowEnd = target.addingTimeInterval(86_400 * 2)
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let instances = store.events(matching: predicate).filter { $0.eventIdentifier == id }
        let best = instances.min { left, right in
            let leftDate: Date = left.safeOccurrence ?? left.safeStart
            let rightDate: Date = right.safeOccurrence ?? right.safeStart
            return abs(leftDate.timeIntervalSince(target)) < abs(rightDate.timeIntervalSince(target))
        }
        if let best, let bestDate = best.safeOccurrence,
           abs(bestDate.timeIntervalSince(target)) < 86_400 * 2 {
            return best
        }
        throw BridgeError.notFound(
            "No occurrence of event '\(id)' near \(Dates.iso(target, timeZone: timeZone)).",
            "List the event first with calendar_list_events and copy the exact occurrenceDate."
        )
    }

    func occurrenceDate(from args: Args) throws -> Date? {
        guard let raw = args.string("occurrence_date") ?? args.string("occurrenceDate") else { return nil }
        return try Dates.parse(raw, timeZone: timeZone).date
    }

    // MARK: Listing

    func eventListJSON(_ args: Args, defaultRange: String) throws -> [String: Any] {
        try requireRead(.event)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let range = try Dates.range(from: args.merging(["range": args.string("range") ?? args.string("preset") ?? defaultRange]), timeZone: zone)

        let calendars = try resolveCalendars(args, entity: .event)
        if calendars == nil, args.boolOr("all_calendars", true) == false {
            throw BridgeError.invalid("all_calendars=false requires explicit calendars.", nil)
        }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        var events = store.events(matching: predicate)

        if let query = clean(args.string("query") ?? args.string("search") ?? args.string("q")) {
            let needle = query.lowercased()
            events = events.filter { event in
                let haystacks = [
                    event.title ?? "",
                    event.location ?? "",
                    event.notes ?? "",
                    event.calendar.title,
                    event.url?.absoluteString ?? "",
                ]
                if haystacks.contains(where: { $0.lowercased().contains(needle) }) { return true }
                if let attendees = event.attendees {
                    return attendees.contains { ($0.name ?? "").lowercased().contains(needle) }
                }
                return false
            }
        }

        if args.boolOr("exclude_all_day", false) {
            events = events.filter { !$0.isAllDay }
        }

        events.sort { ($0.safeStart, $0.safeTitle) < ($1.safeStart, $1.safeTitle) }

        let limit = min(max(1, args.intOr("limit", Env.defaultLimit)), Env.maxLimit)
        let total = events.count
        let limited = Array(events.prefix(limit))
        let details = args.boolOr("include_details", false)

        var result: [String: Any] = [
            "range": [
                "label": range.label,
                "start": Dates.iso(range.start, timeZone: zone),
                "end": Dates.iso(range.end, timeZone: zone),
                "startLocal": Dates.local(range.start, timeZone: zone),
                "endLocal": Dates.local(range.end, timeZone: zone),
            ],
            "timeZone": zone.identifier,
            "calendarFilter": calendars?.map(\.title) ?? ["all"],
            "count": limited.count,
            "totalMatching": total,
            "truncated": total > limited.count,
            "events": limited.map { eventDict($0, includeDetails: details) },
        ]
        if total > limited.count {
            result["limitHint"] = "Showing \(limited.count) of \(total) events. Raise 'limit' or narrow the range."
        }
        return result
    }

    func eventGetJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        let id = try args.requiredString("id")
        let occurrence = try occurrenceDate(from: args)
        let event = try resolveEvent(id: id, occurrenceDate: occurrence)
        return [
            "event": eventDict(event, includeDetails: true),
            "attendeeMutationSupported": false,
            "attendeeNote": "EventKit exposes attendees as read-only. To invite people, create the event with calendar_create_event_in_calendar_app, which hands a prefilled .ics to Calendar.app.",
        ]
    }

    // MARK: Mutation

    func eventCreateJSON(_ args: Args) throws -> [String: Any] {
        try requireWrite(.event)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let title = try args.requiredString("title")
        let calendar = try resolveContainer(
            id: args.string("calendar_id") ?? args.string("calendarId"),
            title: args.string("calendar"),
            entity: .event,
            requireWritable: true
        )

        let allDay = args.boolOr("all_day", args.boolOr("allDay", false))
        let startText = try args.requiredString("start")
        let start = try Dates.parse(startText, timeZone: zone).date

        var end: Date
        if let endText = args.string("end") {
            end = try Dates.parse(endText, timeZone: zone).date
        } else if let minutes = args.int("duration_minutes") ?? args.int("durationMinutes") {
            end = start.addingTimeInterval(Double(minutes) * 60)
        } else if allDay {
            end = start.addingTimeInterval(86_400)
        } else {
            end = start.addingTimeInterval(3_600)
        }

        let summary: [String: Any] = [
            "title": title,
            "calendar": calendar.title,
            "account": calendar.source.title,
            "start": Dates.iso(start, timeZone: zone),
            "end": Dates.iso(end, timeZone: zone),
            "allDay": allDay,
            "startLocal": Dates.local(start, timeZone: zone),
            "endLocal": Dates.local(end, timeZone: zone),
        ]
        if case .halt(let preview) = writeGuard(args, action: "create_event", target: summary) {
            return preview
        }
        try requireWrite(.event)

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        try applyEventFields(event, args: args, zone: zone, isCreate: true)

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw Self.mapError(error, context: "creating the event")
        }
        var result = eventDict(event, includeDetails: true)
        result["applied"] = true
        return ["event": result, "created": true]
    }

    func eventUpdateJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        try requireWrite(.event)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let id = try args.requiredString("id")
        let occurrence = try occurrenceDate(from: args)
        let event = try resolveEvent(id: id, occurrenceDate: occurrence)
        let span = try Self.span(from: args.string("span") ?? args.string("recurrence_span"))

        let before = eventDict(event, includeDetails: true)
        let summary: [String: Any] = ["id": id, "title": before["title"] as? String ?? "", "calendar": before["calendar"] as? String ?? ""]
        if case .halt(let preview) = writeGuard(args, action: "update_event", target: summary, extra: ["before": before]) {
            return preview
        }

        try applyEventFields(event, args: args, zone: zone, isCreate: false)
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw Self.mapError(error, context: "saving the event")
        }
        return [
            "applied": true,
            "span": span == .thisEvent ? "this" : "this_and_future",
            "before": before,
            "after": eventDict(event, includeDetails: true),
        ]
    }

    func eventDeleteJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        try requireWrite(.event)
        let id = try args.requiredString("id")
        let occurrence = try occurrenceDate(from: args)
        let event = try resolveEvent(id: id, occurrenceDate: occurrence)
        guard event.calendar.allowsContentModifications, !event.calendar.isImmutable else {
            throw BridgeError.unsupported(
                "'\(event.calendar.title)' is read-only, so its events cannot be deleted.",
                nil
            )
        }
        let span = try Self.span(from: args.string("span") ?? args.string("recurrence_span"))
        let isRecurring = event.hasRecurrenceRules
        let summary: [String: Any] = [
            "id": id,
            "title": event.title ?? "",
            "calendar": event.calendar.title,
            "start": Dates.iso(event.safeStart, timeZone: timeZone),
            "isRecurring": isRecurring,
            "span": isRecurring ? (span == .thisEvent ? "this occurrence" : "this and future occurrences") : "single event",
        ]
        if case .halt(let preview) = writeGuard(args, action: "delete_event", target: summary) {
            return preview
        }

        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            throw Self.mapError(error, context: "deleting the event")
        }
        return ["applied": true, "deleted": summary]
    }

    func eventMoveJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        try requireWrite(.event)
        let id = try args.requiredString("id")
        let occurrence = try occurrenceDate(from: args)
        let event = try resolveEvent(id: id, occurrenceDate: occurrence)
        let target = try resolveContainer(
            id: args.string("calendar_id") ?? args.string("calendarId"),
            title: args.string("calendar"),
            entity: .event,
            requireWritable: true
        )
        if event.calendar.calendarIdentifier == target.calendarIdentifier {
            return [
                "applied": false,
                "reason": "already_in_target",
                "note": "The event is already in '\(target.title)'.",
            ]
        }
        let span = try Self.span(from: args.string("span") ?? args.string("recurrence_span"))
        let summary: [String: Any] = [
            "id": id,
            "title": event.title ?? "",
            "from": event.calendar.title,
            "to": target.title,
        ]
        if case .halt(let preview) = writeGuard(args, action: "move_event", target: summary) {
            return preview
        }

        event.calendar = target
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            let nsError = error as NSError
            if nsError.domain == EKErrorDomain, EKError.Code(rawValue: nsError.code) == .invitesCannotBeMoved {
                throw BridgeError.unsupported(
                    "This event is an invitation and cannot be moved between calendars.",
                    "Accepting the invitation first usually makes it movable."
                )
            }
            throw Self.mapError(error, context: "moving the event")
        }
        return ["applied": true, "event": eventDict(event, includeDetails: true)]
    }

    func eventDuplicateJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        try requireWrite(.event)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let id = try args.requiredString("id")
        let occurrence = try occurrenceDate(from: args)
        let source = try resolveEvent(id: id, occurrenceDate: occurrence)

        let offsetMinutes = args.int("offset_minutes") ?? args.int("offsetMinutes") ?? 0
        let newStart: Date
        if let startText = args.string("start") {
            newStart = try Dates.parse(startText, timeZone: zone).date
        } else {
            newStart = source.safeStart.addingTimeInterval(Double(offsetMinutes) * 60)
        }
        // Shift both ends by the same delta so an all-day event keeps its shape
        // instead of drifting when the offset is not a whole number of days.
        let newEnd = source.safeEnd.addingTimeInterval(newStart.timeIntervalSince(source.safeStart))

        let target: EKCalendar
        if args.has("calendar") || args.has("calendar_id") || args.has("calendarId") {
            target = try resolveContainer(
                id: args.string("calendar_id") ?? args.string("calendarId"),
                title: args.string("calendar"),
                entity: .event,
                requireWritable: true
            )
        } else {
            target = source.calendar
        }

        let title = args.string("title") ?? ((source.title ?? "") + " (copy)")
        let summary: [String: Any] = [
            "from": source.title ?? "",
            "title": title,
            "calendar": target.title,
            "start": Dates.iso(newStart, timeZone: zone),
            "end": Dates.iso(newEnd, timeZone: zone),
        ]
        if case .halt(let preview) = writeGuard(args, action: "duplicate_event", target: summary) {
            return preview
        }

        let copy = EKEvent(eventStore: store)
        copy.calendar = target
        copy.title = title
        copy.startDate = newStart
        copy.endDate = newEnd
        copy.isAllDay = source.isAllDay
        copy.location = source.location
        copy.notes = source.notes
        copy.url = source.url
        copy.timeZone = source.timeZone
        copy.availability = source.availability
        if let rules = source.recurrenceRules { copy.recurrenceRules = rules }
        if let alarms = source.alarms { copy.alarms = alarms }
        do {
            try store.save(copy, span: .thisEvent, commit: true)
        } catch {
            throw Self.mapError(error, context: "duplicating the event")
        }
        return ["applied": true, "event": eventDict(copy, includeDetails: true)]
    }

    /// Shared field application for create/update.
    func applyEventFields(_ event: EKEvent, args: Args, zone: TimeZone, isCreate: Bool) throws {
        if let title = args.string("title"), !title.isEmpty { event.title = title }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        var parsedStart: Dates.Parsed?
        if let startText = args.string("start") {
            parsedStart = try Dates.parse(startText, timeZone: zone)
        }
        var parsedEnd: Dates.Parsed?
        if let endText = args.string("end") {
            parsedEnd = try Dates.parse(endText, timeZone: zone)
        }
        let durationMinutes = args.int("duration_minutes") ?? args.int("durationMinutes")

        // A bare date means an all-day item, which is what Calendar.app does and
        // what this tool documents. Inferred only on create: moving an existing
        // timed event to another day should not silently drop its times.
        if let explicit = args.bool("all_day") ?? args.bool("allDay") {
            event.isAllDay = explicit
        } else if isCreate,
                  let parsedStart,
                  parsedStart.isDateOnly,
                  parsedEnd?.isDateOnly ?? true,
                  durationMinutes == nil {
            event.isAllDay = true
        }

        var start = parsedStart?.date ?? event.safeStart
        let previousStart: Date? = event.startDate
        let previousEnd: Date? = event.endDate

        var end: Date
        if let given = parsedEnd?.date {
            end = given
        } else if let durationMinutes {
            end = start.addingTimeInterval(Double(durationMinutes) * 60)
        } else if let previousStart, let previousEnd {
            // No end given and the event already exists: keep its original length
            // so moving the start does not turn it into a zero-length event.
            end = start.addingTimeInterval(previousEnd.timeIntervalSince(previousStart))
        } else {
            // New event with no end and no duration: one hour, as documented.
            end = start.addingTimeInterval(3_600)
        }

        if event.isAllDay {
            // EventKit snaps an all-day end date to the end of the day it falls in,
            // so 'end' names the last day the event covers and is inclusive. Using
            // the timed convention here (start + 1 day) makes every all-day event
            // one day too long.
            let startDay = calendar.startOfDay(for: start)
            let days: Int
            if let given = parsedEnd?.date {
                let endDay = calendar.startOfDay(for: given)
                let span = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
                guard span >= 0 else {
                    throw BridgeError.invalid(
                        "The all-day end date is before the start date.",
                        "For an all-day event 'end' names the last day it covers, and may equal 'start' for a single day."
                    )
                }
                days = span + 1
            } else if let durationMinutes, durationMinutes > 0 {
                days = max(1, Int((Double(durationMinutes) / 1_440.0).rounded(.up)))
            } else if isCreate {
                days = 1
            } else {
                days = allDaySpan(start: event.safeStart, end: event.safeEnd, calendar: calendar).days
            }
            start = startDay
            end = allDayEnd(from: startDay, days: days, calendar: calendar)
        }

        guard end > start else {
            throw BridgeError.invalid(
                "The end time must be after the start time.",
                "start=\(Dates.iso(start, timeZone: zone)) end=\(Dates.iso(end, timeZone: zone))"
            )
        }
        event.startDate = start
        event.endDate = end

        if args.has("timezone") || args.has("time_zone") {
            let identifier = args.string("timezone") ?? args.string("time_zone")
            if let identifier, !identifier.isEmpty {
                guard let parsed = TimeZone(identifier: identifier) else {
                    throw BridgeError.invalid("Unknown time zone '\(identifier)'.", nil)
                }
                event.timeZone = parsed
            } else {
                event.timeZone = nil
            }
        }

        if isCreate || args.has("location") {
            if let location = args.string("location") {
                event.location = clean(location)
            }
        }
        if isCreate || args.has("notes") {
            if let notes = args.string("notes") { event.notes = clean(notes) }
        }
        if isCreate || args.has("url") {
            if let url = args.string("url") {
                if let cleaned = clean(url) {
                    guard let parsed = URL(string: cleaned) else {
                        throw BridgeError.invalid("'\(cleaned)' is not a valid URL.", nil)
                    }
                    event.url = parsed
                } else {
                    event.url = nil
                }
            }
        }
        if let availability = args.string("availability") {
            event.availability = try Self.availability(from: availability)
        }
        if args.has("alarms") {
            event.alarms = try alarms(args.objects("alarms"))
        }
        if args.has("recurrence") || args.has("recurrence_rules") {
            let specs = args.objects("recurrence") + args.objects("recurrence_rules")
            event.recurrenceRules = specs.isEmpty ? nil : try recurrenceRules(specs)
        }
        for field in args.strings("clear") {
            switch field.lowercased() {
            case "notes": event.notes = nil
            case "location": event.location = nil
            case "url": event.url = nil
            case "alarms": event.alarms = nil
            case "recurrence", "recurrence_rules": event.recurrenceRules = nil
            case "timezone", "time_zone": event.timeZone = nil
            default:
                throw BridgeError.invalid(
                    "Cannot clear '\(field)'.",
                    "Clearable fields: notes, location, url, alarms, recurrence, timezone."
                )
            }
        }
    }

    // MARK: Conflict + free/busy analysis

    func conflictsJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let range = try Dates.range(from: args, timeZone: zone)
        let calendars = try resolveCalendars(args, entity: .event)
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay || args.boolOr("include_all_day", false) }
            .sorted { $0.safeStart < $1.safeStart }

        var conflicts: [[String: Any]] = []
        for outer in 0..<events.count {
            for inner in (outer + 1)..<events.count {
                let left = events[outer]
                let right = events[inner]
                if right.safeStart >= left.safeEnd { break }
                if left.safeEnd <= right.safeStart { continue }
                let overlapStart = max(left.safeStart, right.safeStart)
                let overlapEnd = min(left.safeEnd, right.safeEnd)
                conflicts.append([
                    "overlapStart": Dates.iso(overlapStart, timeZone: zone),
                    "overlapEnd": Dates.iso(overlapEnd, timeZone: zone),
                    "overlapMinutes": Int(overlapEnd.timeIntervalSince(overlapStart) / 60),
                    "a": ["id": left.safeIdentifier, "title": left.title ?? "", "calendar": left.calendar.title],
                    "b": ["id": right.safeIdentifier, "title": right.title ?? "", "calendar": right.calendar.title],
                ])
            }
        }
        return [
            "range": ["label": range.label, "start": Dates.iso(range.start, timeZone: zone), "end": Dates.iso(range.end, timeZone: zone)],
            "scannedEvents": events.count,
            "conflictCount": conflicts.count,
            "conflicts": conflicts,
        ]
    }

    func freeSlotsJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let range = try Dates.range(from: args, timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let duration = max(5, args.intOr("duration_minutes", 60))
        let workStartParts = Self.parseClock(args.string("workday_start") ?? "09:00")
        let workEndParts = Self.parseClock(args.string("workday_end") ?? "18:00")
        let minimum = max(0, args.intOr("min_lead_minutes", 0))
        let includeFree = args.boolOr("include_free_events", false)
        let includeAllDay = args.boolOr("all_day_blocks", true)

        let calendars = try resolveCalendars(args, entity: .event)
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        let events = store.events(matching: predicate)

        var days: [[String: Any]] = []
        var cursor = calendar.startOfDay(for: range.start)
        let now = Date().addingTimeInterval(Double(minimum) * 60)

        while cursor < range.end {
            guard let windowStart = calendar.date(bySettingHour: workStartParts.0, minute: workStartParts.1, second: 0, of: cursor),
                  let windowEnd = calendar.date(bySettingHour: workEndParts.0, minute: workEndParts.1, second: 0, of: cursor),
                  windowEnd > windowStart
            else {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? range.end
                continue
            }

            let dayEvents = events.filter { event in
                if event.safeStart < windowEnd && event.safeEnd > windowStart {
                    if event.isAllDay && !includeAllDay { return false }
                    if event.availability == .free && !includeFree { return false }
                    return true
                }
                return false
            }

            let busy: [(Date, Date)] = dayEvents.map {
                (max($0.safeStart, windowStart), min($0.safeEnd, windowEnd))
            }.sorted { $0.0 < $1.0 }

            var merged: [(Date, Date)] = []
            for interval in busy {
                if let last = merged.last, interval.0 <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, interval.1)
                } else {
                    merged.append(interval)
                }
            }

            var slots: [[String: Any]] = []
            var pointer = max(windowStart, now)
            for interval in merged {
                if interval.0 > pointer {
                    let length = Int(interval.0.timeIntervalSince(pointer) / 60)
                    if length >= duration {
                        slots.append([
                            "start": Dates.iso(pointer, timeZone: zone),
                            "end": Dates.iso(interval.0, timeZone: zone),
                            "startLocal": Dates.local(pointer, timeZone: zone),
                            "endLocal": Dates.local(interval.0, timeZone: zone),
                            "durationMinutes": length,
                        ])
                    }
                }
                pointer = max(pointer, interval.1)
            }
            if windowEnd > pointer {
                let length = Int(windowEnd.timeIntervalSince(pointer) / 60)
                if length >= duration {
                    slots.append([
                        "start": Dates.iso(pointer, timeZone: zone),
                        "end": Dates.iso(windowEnd, timeZone: zone),
                        "startLocal": Dates.local(pointer, timeZone: zone),
                        "endLocal": Dates.local(windowEnd, timeZone: zone),
                        "durationMinutes": length,
                    ])
                }
            }

            if !slots.isEmpty || args.boolOr("include_empty_days", false) {
                days.append([
                    "date": Dates.dateOnly(cursor, timeZone: zone),
                    "weekday": Dates.local(cursor, timeZone: zone).components(separatedBy: " ").last ?? "",
                    "window": ["start": Dates.iso(windowStart, timeZone: zone), "end": Dates.iso(windowEnd, timeZone: zone)],
                    "busyCount": dayEvents.count,
                    "freeSlots": slots,
                ])
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? range.end
        }

        return [
            "range": ["label": range.label, "start": Dates.iso(range.start, timeZone: zone), "end": Dates.iso(range.end, timeZone: zone)],
            "timeZone": zone.identifier,
            "requestedDurationMinutes": duration,
            "workday": ["start": String(format: "%02d:%02d", workStartParts.0, workStartParts.1), "end": String(format: "%02d:%02d", workEndParts.0, workEndParts.1)],
            "days": days,
        ]
    }

    static func parseClock(_ text: String) -> (Int, Int) {
        let parts = text.split(separator: ":")
        let hour = parts.count > 0 ? (Int(parts[0]) ?? 9) : 9
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (min(max(hour, 0), 23), min(max(minute, 0), 59))
    }

    // MARK: Natural language quick add

    func quickAddJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.event)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let text = try args.requiredString("text")

        var matchedDate: Date?
        var matchedText: String?
        var remainder = text

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = detector.matches(in: text, options: [], range: range)
            if let match = matches.first, let date = match.date, let swiftRange = Range(match.range, in: text) {
                matchedDate = date
                matchedText = String(text[swiftRange])
                remainder = text.replacingCharacters(in: swiftRange, with: " ")
            }
        }

        if matchedDate == nil {
            if let parsed = try? Dates.parse(text, timeZone: zone, futureBias: true) {
                matchedDate = parsed.date
                matchedText = text
                remainder = " "
            }
        }

        guard var start = matchedDate else {
            throw BridgeError.invalid(
                "Could not find a date or time in '\(text)'.",
                "Add an explicit time (\"tomorrow 15:00\") or pass start/end explicitly with calendar_create_event."
            )
        }

        var allDay = args.boolOr("all_day", false)
        let allDayKeywords = ["all-day", "all day", "allday", "全天事件", "全天"]
        if allDayKeywords.contains(where: { text.lowercased().contains($0) }) {
            allDay = true
            for keyword in allDayKeywords {
                remainder = remainder.replacingOccurrences(of: keyword, with: " ", options: [.caseInsensitive])
            }
        }

        /// A phrase with no time of day means the whole day, matching how
        /// Calendar.app reads a bare date.
        func mentionsTimeOfDay(_ value: String) -> Bool {
            if value.range(of: #"\d{1,2}\s*[:：]\s*\d{2}"#, options: .regularExpression) != nil { return true }
            if value.range(of: #"\d{1,2}\s*(点|时)"#, options: .regularExpression) != nil { return true }
            let lowered = value.lowercased()
            return ["am", "pm", "早上", "上午", "中午", "下午", "晚上", "傍晚"]
                .contains { lowered.contains($0) }
        }

        var durationMinutes = args.int("duration_minutes")
        if durationMinutes == nil,
           let match = Dates.firstMatch(#"(\d+(?:\.\d+)?)\s*(?:个)?\s*(minutes?|mins?|m|hours?|hrs?|h|小时|分钟)"#, in: remainder),
           match.groups.count >= 2 {
            if let amount = Double(match.groups[0]) {
                let unit = match.groups[1].lowercased()
                durationMinutes = Int(amount * (unit.hasPrefix("h") || unit == "小时" ? 60 : 1))
            }
            if let swiftRange = remainder.range(of: match.full) {
                remainder = remainder.replacingCharacters(in: swiftRange, with: " ")
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        if args.bool("all_day") == nil,
           !allDay,
           durationMinutes == nil,
           let matched = matchedText,
           !mentionsTimeOfDay(matched) {
            allDay = true
        }

        if allDay {
            start = calendar.startOfDay(for: start)
        }

        let duration = durationMinutes ?? (allDay ? 1_440 : 60)
        let end: Date
        if allDay {
            let days = max(1, Int((Double(duration) / 1_440.0).rounded(.up)))
            end = allDayEnd(from: start, days: days, calendar: calendar)
        } else {
            end = start.addingTimeInterval(Double(duration) * 60)
        }

        let cleanedTitle = remainder
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,，。.。@-–—|、:："))
        let title = args.string("title") ?? (cleanedTitle.isEmpty ? "Untitled event" : cleanedTitle)

        let target = try resolveContainer(
            id: args.string("calendar_id") ?? args.string("calendarId"),
            title: args.string("calendar"),
            entity: .event,
            requireWritable: true
        )

        let summary: [String: Any] = [
            "title": title,
            "calendar": target.title,
            "start": Dates.iso(start, timeZone: zone),
            "end": Dates.iso(end, timeZone: zone),
            "allDay": allDay,
            "startLocal": Dates.local(start, timeZone: zone),
            "endLocal": Dates.local(end, timeZone: zone),
            "parsedFrom": ["input": text, "dateText": matchedText ?? "", "durationSource": durationMinutes == nil ? "default" : "text"],
        ]
        if case .halt(let preview) = writeGuard(args, action: "quick_add", target: summary) {
            return preview
        }

        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = title
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = end
        if let location = args.string("location") { event.location = location }
        if let notes = args.string("notes") { event.notes = notes }
        if let url = args.string("url"), let parsed = URL(string: url) { event.url = parsed }
        let alarmSpecs = args.objects("alarms")
        if !alarmSpecs.isEmpty { event.alarms = try alarms(alarmSpecs) }
        if !args.objects("recurrence").isEmpty { event.recurrenceRules = try recurrenceRules(args.objects("recurrence")) }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw Self.mapError(error, context: "creating the event from natural language")
        }
        return ["applied": true, "event": eventDict(event, includeDetails: true), "parsed": summary]
    }
}

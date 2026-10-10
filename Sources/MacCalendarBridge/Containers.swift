import EventKit
import Foundation

// MARK: - Diagnostics, accounts, containers, ICS handoff

extension Store {

    // MARK: Diagnostics

    func statusJSON() -> [String: Any] {
        var report = permissionReport()
        report["bridge"] = [
            "name": "mac-calendar-bridge",
            "version": Env.bridgeVersion,
            "writeMode": Env.writeMode,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]

        var accounts: [[String: Any]] = []
        if Self.canRead(eventAuthorization) || Self.canRead(reminderAuthorization) {
            accounts = sources().map(sourceDict)
        }
        report["accounts"] = accounts
        report["accountCount"] = accounts.count

        var defaults: [String: Any] = [:]
        let pinned = Preferences.load()
        if let pinnedEvent = pinned.eventCalendarId,
           let calendar = store.calendar(withIdentifier: pinnedEvent) {
            defaults["bridgeDefaultCalendar"] = ["id": calendar.calendarIdentifier, "title": calendar.title]
        }
        if let pinnedList = pinned.reminderListId,
           let calendar = store.calendar(withIdentifier: pinnedList) {
            defaults["bridgeDefaultReminderList"] = ["id": calendar.calendarIdentifier, "title": calendar.title]
        }
        let eventDefault: EKCalendar? = store.defaultCalendarForNewEvents
        if let eventDefault {
            defaults["systemDefaultCalendar"] = ["id": eventDefault.calendarIdentifier, "title": eventDefault.title]
        }
        let reminderDefault: EKCalendar? = store.defaultCalendarForNewReminders()
        if let reminderDefault {
            defaults["systemDefaultReminderList"] = ["id": reminderDefault.calendarIdentifier, "title": reminderDefault.title]
        }
        defaults["preferencesFile"] = Preferences.fileURL.path
        report["defaults"] = defaults

        var counts: [String: Any] = [:]
        if Self.canRead(eventAuthorization) {
            counts["eventCalendars"] = calendars(for: .event).count
        } else {
            counts["eventCalendars"] = NSNull()
        }
        if Self.canRead(reminderAuthorization) {
            counts["reminderLists"] = calendars(for: .reminder).count
        } else {
            counts["reminderLists"] = NSNull()
        }
        report["counts"] = counts
        report["knownLimitations"] = [
            "EventKit attendees are read-only: inviting people requires calendar_create_event_in_calendar_app (opens a prefilled event in Calendar.app).",
            "Reminders 'flagged' has no EventKit API; priority is exposed instead.",
            "The macOS system default calendar/list cannot be changed by any API; calendars_set_default pins a default inside this bridge instead.",
            "A calendar cannot be moved between accounts; recreate it and move its events.",
        ]
        return report
    }

    func accountsJSON(_ args: Args) throws -> [String: Any] {
        let reachable = Self.canRead(eventAuthorization) || Self.canRead(reminderAuthorization)
        guard reachable else {
            throw BridgeError.denied(
                "Neither Calendar nor Reminders read access is granted.",
                "Grant Full Access in System Settings › Privacy & Security, then retry calendars_status."
            )
        }
        return [
            "count": sources().count,
            "accounts": sources().map(sourceDict),
            "note": "An account (EKSource) is the container of containers; calendars and reminder lists live inside one.",
        ]
    }

    // MARK: Container listing / mutation

    func containerListJSON(_ args: Args, entity: EKEntityType) throws -> [String: Any] {
        try requireRead(entity)
        var result = listContainers(
            entity: entity,
            account: args.string("account"),
            writableOnly: args.boolOr("writable_only", false)
        )
        result["preferredDefaultId"] = Preferences.defaultContainerId(entity: entity) as Any? ?? NSNull()
        let systemDefault: EKCalendar? = entity == .event
            ? store.defaultCalendarForNewEvents
            : store.defaultCalendarForNewReminders()
        result["systemDefaultId"] = systemDefault?.calendarIdentifier as Any? ?? NSNull()
        result["note"] = entity == .event
            ? "Use the value of `id` (or `title`) as the 'calendar' / 'calendar_id' argument of the other tools."
            : "Use the value of `id` (or `title`) as the 'list' / 'list_id' argument of the other tools."
        return result
    }

    func containerCreateJSON(_ args: Args, entity: EKEntityType) throws -> [String: Any] {
        try requireRead(entity)
        try requireWrite(entity)
        let title = try args.requiredString("title")
        let colorHex = args.string("color") ?? args.string("color_hex") ?? args.string("colorHex")
        let account = args.string("account")
        let calendarName = entity == .event ? "Calendar" : "Reminder list"

        var summary: [String: Any] = ["kind": calendarName, "title": title]
        if let colorHex {
            let color = try Colors.color(colorHex)
            summary["colorHex"] = Colors.hex(color) as Any? ?? colorHex
        }
        if let account { summary["account"] = account }
        if case .halt(let preview) = writeGuard(args, action: "create_container", target: summary) {
            return preview
        }

        let calendar = try createContainer(entity: entity, title: title, colorHex: colorHex, account: account)
        return [
            "applied": true,
            "created": true,
            "container": containerDict(calendar),
        ]
    }

    func containerUpdateJSON(_ args: Args, entity: EKEntityType) throws -> [String: Any] {
        try requireRead(entity)
        try requireWrite(entity)
        let calendar = try resolveContainer(
            id: args.string("id") ?? args.string("calendar_id") ?? args.string("list_id"),
            title: args.string("calendar") ?? args.string("title_match") ?? args.string("list"),
            entity: entity,
            requireWritable: true
        )
        let before = containerDict(calendar)
        let newTitle = args.string("new_title") ?? args.string("title")
        let colorHex = args.string("color") ?? args.string("color_hex") ?? args.string("colorHex")

        guard newTitle != nil || colorHex != nil else {
            throw BridgeError.invalid(
                "Nothing to update.",
                "Pass 'new_title' and/or 'color'. To move a container between accounts, see the note in the result of calendars_status: it is not possible."
            )
        }

        var summary: [String: Any] = ["id": calendar.calendarIdentifier, "title": calendar.title]
        if let newTitle { summary["newTitle"] = newTitle }
        if let colorHex {
            let color = try Colors.color(colorHex)
            summary["colorHex"] = Colors.hex(color) as Any? ?? colorHex
        }
        if case .halt(let preview) = writeGuard(args, action: "update_container", target: summary, extra: ["before": before]) {
            return preview
        }

        let updated = try updateContainer(calendar, newTitle: newTitle, newColorHex: colorHex)
        return [
            "applied": true,
            "before": before,
            "after": containerDict(updated),
        ]
    }

    func containerDeleteJSON(_ args: Args, entity: EKEntityType) throws -> [String: Any] {
        try requireRead(entity)
        try requireWrite(entity)
        let calendar = try resolveContainer(
            id: args.string("id") ?? args.string("calendar_id") ?? args.string("list_id"),
            title: args.string("calendar") ?? args.string("title_match") ?? args.string("list"),
            entity: entity,
            requireWritable: true
        )
        let counts = containerItemCounts(calendar)
        let itemTotal = (counts["eventCount"] as? Int ?? 0) + (counts["reminderCount"] as? Int ?? 0)
        let acknowledged = args.boolOr("confirm_delete_contents", false) || args.boolOr("confirmDeleteContents", false)

        if itemTotal > 0 && !acknowledged {
            return [
                "applied": false,
                "allowed": false,
                "reason": "container_not_empty",
                "container": counts,
                "hint": "Deleting '\(calendar.title)' also deletes the items inside it, and the change syncs to every device on the account. Re-issue with \"confirm_delete_contents\": true (plus \"confirm\": true when writeMode is 'ask') to proceed, or move the items to another container first.",
                "alternative": entity == .event
                    ? "calendar_move_event can relocate events one at a time."
                    : "reminders_move can relocate reminders in bulk.",
            ]
        }

        var summary: [String: Any] = [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "account": calendar.source.title,
            "itemCounts": counts,
        ]
        summary["deletesContents"] = itemTotal > 0
        if case .halt(let preview) = writeGuard(args, action: "delete_container", target: summary) {
            return preview
        }

        try deleteContainer(calendar)
        for entityType in [EKEntityType.event, EKEntityType.reminder] {
            if Preferences.defaultContainerId(entity: entityType) == calendar.calendarIdentifier {
                try? Preferences.clear(entity: entityType)
            }
        }
        return ["applied": true, "deleted": summary]
    }

    func containerSetDefaultJSON(_ args: Args, entity: EKEntityType) throws -> [String: Any] {
        try requireRead(entity)
        if args.boolOr("clear", false) {
            try Preferences.clear(entity: entity)
            return [
                "applied": true,
                "cleared": true,
                "note": "The bridge no longer pins a default; tools fall back to the macOS system default.",
            ]
        }
        let calendar = try resolveContainer(
            id: args.string("id") ?? args.string("calendar_id"),
            title: args.string("calendar") ?? args.string("list"),
            entity: entity
        )
        var summary: [String: Any] = ["id": calendar.calendarIdentifier, "title": calendar.title]
        summary["kind"] = entity == .event ? "calendar" : "reminder list"
        if case .halt(let preview) = writeGuard(args, action: "set_default_container", target: summary) {
            return preview
        }

        try Preferences.save(
            eventCalendarId: entity == .event ? calendar.calendarIdentifier : nil,
            reminderListId: entity == .reminder ? calendar.calendarIdentifier : nil,
            timeZoneIdentifier: nil
        )
        return [
            "applied": true,
            "defaultContainer": summary,
            "preferencesFile": Preferences.fileURL.path,
            "note": "This is the bridge's own default, used when a tool is called without 'calendar'/'list'. macOS does not allow changing the system default programmatically.",
        ]
    }

    // MARK: Calendar.app handoff (ICS)

    /// EventKit cannot add invitees, attachments, or conference data. Writing a
    /// temporary `.ics` and handing it to Calendar.app covers those cases while
    /// keeping the user in control of what actually lands in the calendar.
    func calendarAppHandoffJSON(_ args: Args) throws -> [String: Any] {
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let title = try args.requiredString("title")
        let start = try Dates.parse(try args.requiredString("start"), timeZone: zone).date
        let allDay = args.boolOr("all_day", false)
        let end: Date
        if let endText = args.string("end") {
            end = try Dates.parse(endText, timeZone: zone).date
        } else if let minutes = args.int("duration_minutes") {
            end = start.addingTimeInterval(Double(minutes) * 60)
        } else {
            end = start.addingTimeInterval(allDay ? 86_400 : 3_600)
        }

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//mac-calendar-bridge//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-TIMEZONE:\(zone.identifier)",
            "BEGIN:VEVENT",
            "UID:\(UUID().uuidString)@mac-calendar-bridge",
            "DTSTAMP:\(Self.icsTimestamp(Date(), zone: .gmt))",
        ]

        if allDay {
            lines.append("DTSTART;VALUE=DATE:\(Self.icsDate(start, zone: zone))")
            lines.append("DTEND;VALUE=DATE:\(Self.icsDate(end, zone: zone))")
        } else {
            lines.append("DTSTART;TZID=\(zone.identifier):\(Self.icsTimestamp(start, zone: zone))")
            lines.append("DTEND;TZID=\(zone.identifier):\(Self.icsTimestamp(end, zone: zone))")
        }
        lines.append("SUMMARY:\(Self.icsEscape(title))")
        if let location = args.string("location") { lines.append("LOCATION:\(Self.icsEscape(location))") }
        if let notes = args.string("notes") { lines.append("DESCRIPTION:\(Self.icsEscape(notes))") }
        if let url = args.string("url") { lines.append("URL:\(Self.icsEscape(url))") }
        if let availability = args.string("availability") {
            let transp = availability.lowercased() == "free" ? "TRANSPARENT" : "OPAQUE"
            lines.append("TRANSP:\(transp)")
        }
        for attendee in args.strings("attendees") {
            let address = attendee.contains("@") ? attendee : attendee
            lines.append("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:\(address)")
        }
        for minutes in args.array("alarm_minutes_before") {
            let value = (minutes as? NSNumber)?.intValue ?? Int("\(minutes)") ?? 15
            lines.append("BEGIN:VALARM")
            lines.append("TRIGGER:-PT\(value)M")
            lines.append("ACTION:DISPLAY")
            lines.append("DESCRIPTION:\(Self.icsEscape(title))")
            lines.append("END:VALARM")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        let body = lines.joined(separator: "\r\n") + "\r\n"
        let fileName = "mac-calendar-\(Int(Date().timeIntervalSince1970)).ics"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        var summary: [String: Any] = [
            "title": title,
            "start": Dates.iso(start, timeZone: zone),
            "end": Dates.iso(end, timeZone: zone),
            "allDay": allDay,
            "icsPath": url.path,
            "attendees": args.strings("attendees"),
        ]
        if case .halt(let preview) = writeGuard(args, action: "handoff_to_calendar_app", target: summary) {
            return preview
        }

        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw BridgeError.failed("Could not write \(url.path): \(error.localizedDescription)", nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Calendar", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw BridgeError.failed(
                "Could not hand the event to Calendar.app: \(error.localizedDescription)",
                "The .ics file is still at \(url.path); open it manually."
            )
        }
        guard process.terminationStatus == 0 else {
            throw BridgeError.failed(
                "Calendar.app refused to open the event file (exit \(process.terminationStatus)).",
                "Open \(url.path) manually."
            )
        }

        summary["applied"] = false
        summary["handedOff"] = true
        summary["note"] = "Calendar.app is showing the event with an Add/Don't Add prompt. Nothing is saved until the user confirms there. This path exists because EventKit cannot add invitees."
        return summary
    }

    static func icsEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func icsDate(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func icsTimestamp(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }
}

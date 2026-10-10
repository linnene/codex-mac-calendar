import CoreLocation
import EventKit
import Foundation

// MARK: - Reminders

extension Store {

    // MARK: Date components

    /// Convert an `EKReminder` due date into a JSON-friendly description.
    func dueInfo(_ reminder: EKReminder) -> [String: Any] {
        guard let date = dateFromDue(reminder) else { return [:] }
        let dateOnly = (reminder.dueDateComponents?.hour == nil)
            && (reminder.dueDateComponents?.minute == nil)
        var entry: [String: Any] = [
            "iso": Dates.iso(date, timeZone: timeZone),
            "local": Dates.local(date, timeZone: timeZone),
            "dateOnly": dateOnly,
            "overdue": !reminder.isCompleted && date < Date(),
        ]
        if dateOnly { entry["date"] = Dates.dateOnly(date, timeZone: timeZone) }
        return entry
    }

    func dateFromDue(_ reminder: EKReminder) -> Date? {
        guard let raw = reminder.dueDateComponents else { return nil }
        var components = raw
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if components.calendar == nil { components.calendar = calendar }
        if components.timeZone == nil { components.timeZone = timeZone }
        return components.date
    }

    func dateFromComponents(_ raw: DateComponents?) -> Date? {
        guard let raw else { return nil }
        var components = raw
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if components.calendar == nil { components.calendar = calendar }
        if components.timeZone == nil { components.timeZone = timeZone }
        return components.date
    }

    func components(from date: Date, dateOnly: Bool, zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts: Set<Calendar.Component> = dateOnly
            ? [.year, .month, .day]
            : [.year, .month, .day, .hour, .minute]
        var components = calendar.dateComponents(parts, from: date)
        components.calendar = calendar
        components.timeZone = zone
        return components
    }

    // MARK: Serialisation

    func reminderDict(_ reminder: EKReminder, includeDetails: Bool = true) -> [String: Any] {
        var entry: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": reminder.calendar.title,
            "listId": reminder.calendar.calendarIdentifier,
            "account": reminder.calendar.source.title,
            "completed": reminder.isCompleted,
            "priority": Int(reminder.priority),
            "priorityLabel": Self.urgencyLabel(Int(reminder.priority)),
            "isRecurring": reminder.hasRecurrenceRules,
            "writable": reminder.calendar.allowsContentModifications
                && !reminder.calendar.isImmutable
                && !reminder.calendar.isSubscribed,
        ]
        if let hex = Colors.hex(reminder.calendar.color) {
            entry["colorHex"] = hex
        } else {
            entry["colorHex"] = NSNull()
        }

        let due = dueInfo(reminder)
        if !due.isEmpty { entry["due"] = due }

        if let completion = reminder.completionDate {
            entry["completionDate"] = Dates.iso(completion, timeZone: timeZone)
        }
        if let start = dateFromComponents(reminder.startDateComponents) {
            entry["startDate"] = Dates.iso(start, timeZone: timeZone)
        }

        guard includeDetails else { return entry }

        let (notes, truncated) = truncateBody(reminder.notes, label: "notes")
        if let notes { entry["notes"] = notes }
        if truncated { entry["notesTruncated"] = true }
        if let url = reminder.url { entry["url"] = url.absoluteString }
        if let location = clean(reminder.location) { entry["location"] = location }
        if let alarms = reminder.alarms, !alarms.isEmpty {
            entry["alarms"] = alarms.map(alarmDict)
        }
        if let rules = reminder.recurrenceRules, !rules.isEmpty {
            entry["recurrence"] = rules.map(recurrenceDict)
        }
        if let created = reminder.creationDate { entry["created"] = Dates.iso(created, timeZone: timeZone) }
        if let modified = reminder.lastModifiedDate { entry["lastModified"] = Dates.iso(modified, timeZone: timeZone) }
        return entry
    }

    // MARK: Listing

    func reminderListJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.reminder)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone

        let calendars = try resolveCalendars(args, entity: .reminder)
        let status = (args.string("status") ?? args.string("state") ?? "incomplete").lowercased()
        let predicate: NSPredicate
        switch status {
        case "completed", "done", "finished":
            predicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: nil, ending: nil, calendars: calendars
            )
        case "all", "any", "*":
            predicate = store.predicateForReminders(in: calendars)
        case "incomplete", "open", "todo", "pending":
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars
            )
        default:
            throw BridgeError.invalid("Unknown status '\(status)'.", "Use incomplete, completed, or all.")
        }

        let fetched = try waitFor { (completion: @escaping ([EKReminder]) -> Void) in
            self.store.fetchReminders(matching: predicate) { reminders in
                completion(reminders ?? [])
            }
        }
        let scanned = fetched.count
        var reminders = fetched

        if let query = clean(args.string("query") ?? args.string("search") ?? args.string("q")) {
            let needle = query.lowercased()
            reminders = reminders.filter { reminder in
                [reminder.title ?? "", reminder.notes ?? "", reminder.calendar.title]
                    .contains { $0.lowercased().contains(needle) }
            }
        }

        if let hasDue = args.bool("has_due") {
            reminders = reminders.filter { ($0.dueDateComponents != nil) == hasDue }
        }

        if args.boolOr("overdue_only", false) {
            let now = Date()
            reminders = reminders.filter { reminder in
                guard !reminder.isCompleted, let due = self.dateFromDue(reminder) else { return false }
                return due < now
            }
        }

        if let dueAfterText = args.string("due_after") {
            let boundary = try Dates.parse(dueAfterText, timeZone: zone).date
            reminders = reminders.filter { ($0.dueDateComponents != nil) && (self.dateFromDue($0) ?? .distantPast) >= boundary }
        }
        if let dueBeforeText = args.string("due_before") {
            let boundary = try Dates.parse(dueBeforeText, timeZone: zone).date
            reminders = reminders.filter { ($0.dueDateComponents != nil) && (self.dateFromDue($0) ?? .distantFuture) <= boundary }
        }
        if let dueOnText = args.string("due_on") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let day = calendar.startOfDay(for: try Dates.parse(dueOnText, timeZone: zone).date)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            reminders = reminders.filter { reminder in
                guard let due = self.dateFromDue(reminder) else { return false }
                return due >= day && due < dayEnd
            }
        }
        if let priorityText = args.string("priority") {
            let wanted = Self.urgencyLabel(try Self.priority(from: priorityText))
            reminders = reminders.filter { Self.urgencyLabel(Int($0.priority)) == wanted }
        }

        let sort = (args.string("sort") ?? "due").lowercased()
        switch sort {
        case "created":
            reminders.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case "completion", "completed":
            reminders.sort { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
        case "priority":
            reminders.sort { left, right in
                let leftScore = left.priority == 0 ? 99 : Int(left.priority)
                let rightScore = right.priority == 0 ? 99 : Int(right.priority)
                if leftScore != rightScore { return leftScore < rightScore }
                return (left.title ?? "") < (right.title ?? "")
            }
        case "title":
            reminders.sort { ($0.title ?? "") < ($1.title ?? "") }
        case "list":
            reminders.sort {
                if $0.calendar.title != $1.calendar.title { return $0.calendar.title < $1.calendar.title }
                return ($0.title ?? "") < ($1.title ?? "")
            }
        default:
            reminders.sort { left, right in
                let leftDue = self.dateFromDue(left)
                let rightDue = self.dateFromDue(right)
                switch (leftDue, rightDue) {
                case let (l?, r?):
                    if l != r { return l < r }
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    break
                }
                let leftScore = left.priority == 0 ? 99 : Int(left.priority)
                let rightScore = right.priority == 0 ? 99 : Int(right.priority)
                if leftScore != rightScore { return leftScore < rightScore }
                return (left.title ?? "") < (right.title ?? "")
            }
        }

        let limit = min(max(1, args.intOr("limit", Env.defaultLimit)), Env.maxLimit)
        let total = reminders.count
        let limited = Array(reminders.prefix(limit))
        let details = args.boolOr("include_details", false)

        var result: [String: Any] = [
            "status": status,
            "listFilter": calendars?.map(\.title) ?? ["all"],
            "scanned": scanned,
            "count": limited.count,
            "totalMatching": total,
            "truncated": total > limited.count,
            "reminders": limited.map { reminderDict($0, includeDetails: details) },
        ]
        if scanned > 3_000 {
            result["scannedWarning"] = "Fetched \(scanned) reminders before filtering. Narrow with 'lists' or a due range for speed."
        }
        if total > limited.count {
            result["limitHint"] = "Showing \(limited.count) of \(total). Raise 'limit' or narrow the filter."
        }
        return result
    }

    func resolveReminder(id: String) throws -> EKReminder {
        guard let item = store.calendarItem(withIdentifier: id) else {
            throw BridgeError.notFound(
                "No reminder with id '\(id)'.",
                "Ids come from reminders_list. Pass 'id' or 'ids' exactly as returned."
            )
        }
        guard let reminder = item as? EKReminder else {
            throw BridgeError.invalid(
                "'\(id)' is an event, not a reminder.",
                "Use calendar_get_event / calendar_update_event for events."
            )
        }
        return reminder
    }

    func reminderGetJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.reminder)
        let reminder = try resolveReminder(id: try args.requiredString("id"))
        return [
            "reminder": reminderDict(reminder, includeDetails: true),
            "flaggedSupported": false,
            "flaggedNote": "EventKit has no API for the Reminders 'flagged' flag; use priority instead.",
        ]
    }

    // MARK: Mutation

    func reminderCreateJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.reminder)
        try requireWrite(.reminder)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let title = try args.requiredString("title")
        let list = try resolveContainer(
            id: args.string("list_id") ?? args.string("listId") ?? args.string("calendar_id"),
            title: args.string("list") ?? args.string("calendar"),
            entity: .reminder,
            requireWritable: true
        )

        var summary: [String: Any] = ["title": title, "list": list.title, "account": list.source.title]
        if let dueText = args.string("due") ?? args.string("due_date") {
            let parsed = try Dates.parse(dueText, timeZone: zone)
            summary["due"] = Dates.iso(parsed.date, timeZone: zone)
            summary["dueDateOnly"] = parsed.isDateOnly
        }
        if let priorityText = args.string("priority") {
            summary["priority"] = Self.urgencyLabel(try Self.priority(from: priorityText))
        }
        if case .halt(let preview) = writeGuard(args, action: "create_reminder", target: summary) {
            return preview
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        try applyReminderFields(reminder, args: args, zone: zone, isCreate: true)

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw Self.mapError(error, context: "creating the reminder")
        }
        return ["applied": true, "created": true, "reminder": reminderDict(reminder, includeDetails: true)]
    }

    func reminderUpdateJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.reminder)
        try requireWrite(.reminder)
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let id = try args.requiredString("id")
        let reminder = try resolveReminder(id: id)
        let before = reminderDict(reminder, includeDetails: true)
        let summary: [String: Any] = [
            "id": id,
            "title": reminder.title ?? "",
            "list": reminder.calendar.title,
        ]
        if case .halt(let preview) = writeGuard(args, action: "update_reminder", target: summary, extra: ["before": before]) {
            return preview
        }

        try applyReminderFields(reminder, args: args, zone: zone, isCreate: false)

        let wantsMove = args.has("list") || args.has("calendar") || args.has("list_id")
            || args.has("listId") || args.has("calendar_id")
        if wantsMove {
            reminder.calendar = try resolveContainer(
                id: args.string("list_id") ?? args.string("listId") ?? args.string("calendar_id"),
                title: args.string("list") ?? args.string("calendar"),
                entity: .reminder,
                requireWritable: true
            )
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw Self.mapError(error, context: "saving the reminder")
        }
        return [
            "applied": true,
            "before": before,
            "after": reminderDict(reminder, includeDetails: true),
        ]
    }

    func applyReminderFields(_ reminder: EKReminder, args: Args, zone: TimeZone, isCreate: Bool) throws {
        if let title = args.string("title"), !title.isEmpty { reminder.title = title }

        if isCreate || args.has("notes") {
            if let notes = args.string("notes") { reminder.notes = clean(notes) }
        }
        if isCreate || args.has("url") {
            if let url = args.string("url") {
                if let cleaned = clean(url) {
                    guard let parsed = URL(string: cleaned) else {
                        throw BridgeError.invalid("'\(cleaned)' is not a valid URL.", nil)
                    }
                    reminder.url = parsed
                } else {
                    reminder.url = nil
                }
            }
        }
        if isCreate || args.has("location") {
            if let location = args.string("location") { reminder.location = clean(location) }
        }
        if let priorityText = args.string("priority") {
            reminder.priority = try Self.priority(from: priorityText)
        }

        if isCreate || args.has("due") || args.has("due_date") {
            if let dueText = args.string("due") ?? args.string("due_date"), !dueText.isEmpty {
                let parsed = try Dates.parse(dueText, timeZone: zone)
                let dateOnly = args.bool("due_date_only") ?? parsed.isDateOnly
                reminder.dueDateComponents = components(from: parsed.date, dateOnly: dateOnly, zone: zone)
            } else {
                reminder.dueDateComponents = nil
            }
        }

        if args.has("start_date") || args.has("start") {
            if let startText = args.string("start_date") ?? args.string("start"), !startText.isEmpty {
                let parsed = try Dates.parse(startText, timeZone: zone)
                let dateOnly = args.bool("start_date_only") ?? parsed.isDateOnly
                reminder.startDateComponents = components(from: parsed.date, dateOnly: dateOnly, zone: zone)
            } else {
                reminder.startDateComponents = nil
            }
        }

        if args.has("alarms") || args.has("remind_at") || args.has("remind_at_minutes") {
            var specs = args.objects("alarms")
            if let minutes = args.int("remind_at_minutes") {
                specs.append(Args(["minutes_before": minutes]))
            }
            for item in args.array("remind_at") {
                if let number = item as? NSNumber {
                    specs.append(Args(["minutes_before": number.intValue]))
                } else if let text = item as? String {
                    if let minutes = Int(text) {
                        specs.append(Args(["minutes_before": minutes]))
                    } else {
                        let parsed = try Dates.parse(text, timeZone: zone)
                        specs.append(Args(["at": Dates.iso(parsed.date, timeZone: zone)]))
                    }
                }
            }
            reminder.alarms = specs.isEmpty ? nil : try alarms(specs)
        }

        if args.has("recurrence") || args.has("recurrence_rules") {
            let specs = args.objects("recurrence") + args.objects("recurrence_rules")
            if specs.isEmpty {
                reminder.recurrenceRules = nil
            } else {
                if reminder.dueDateComponents == nil {
                    throw BridgeError.invalid(
                        "A recurring reminder requires a due date.",
                        "Pass 'due' together with 'recurrence'."
                    )
                }
                reminder.recurrenceRules = try recurrenceRules(specs)
            }
        }

        if args.bool("flagged") == true {
            throw BridgeError.unsupported(
                "EventKit does not expose the Reminders 'flagged' flag.",
                "Use 'priority': 'high' is the closest supported signal."
            )
        }

        for field in args.strings("clear") {
            switch field.lowercased() {
            case "notes": reminder.notes = nil
            case "url": reminder.url = nil
            case "location": reminder.location = nil
            case "due", "due_date": reminder.dueDateComponents = nil
            case "start", "start_date": reminder.startDateComponents = nil
            case "alarms": reminder.alarms = nil
            case "recurrence", "recurrence_rules": reminder.recurrenceRules = nil
            default:
                throw BridgeError.invalid(
                    "Cannot clear '\(field)'.",
                    "Clearable fields: notes, url, location, due, start, alarms, recurrence."
                )
            }
        }
    }

    func reminderCompleteJSON(_ args: Args, complete: Bool) throws -> [String: Any] {
        try requireRead(.reminder)
        try requireWrite(.reminder)
        let ids = try reminderIds(args)
        let reminders = try ids.map { try resolveReminder(id: $0) }

        let summary: [String: Any] = [
            "action": complete ? "complete" : "uncomplete",
            "count": reminders.count,
            "titles": reminders.map { $0.title ?? "" },
        ]
        if case .halt(let preview) = writeGuard(
            args,
            action: complete ? "complete_reminders" : "uncomplete_reminders",
            target: summary
        ) {
            return preview
        }

        let completionDate: Date
        if let text = args.string("completed_at") {
            completionDate = try Dates.parse(text, timeZone: timeZone).date
        } else {
            completionDate = Date()
        }

        var changed: [[String: Any]] = []
        for reminder in reminders {
            guard reminder.calendar.allowsContentModifications, !reminder.calendar.isImmutable else {
                changed.append([
                    "id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "applied": false,
                    "reason": "list '\(reminder.calendar.title)' is read-only",
                ])
                continue
            }
            reminder.isCompleted = complete
            reminder.completionDate = complete ? completionDate : nil
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw Self.mapError(error, context: "updating completion for '\(reminder.title ?? "")'")
            }
            changed.append([
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "completed": reminder.isCompleted,
            ])
        }
        return ["applied": true, "changed": changed, "count": changed.count]
    }

    func reminderDeleteJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.reminder)
        try requireWrite(.reminder)
        let ids = try reminderIds(args)
        let reminders = try ids.map { try resolveReminder(id: $0) }

        let summary: [String: Any] = [
            "count": reminders.count,
            "items": reminders.map {
                ["id": $0.calendarItemIdentifier, "title": $0.title ?? "", "list": $0.calendar.title]
            },
        ]
        if case .halt(let preview) = writeGuard(args, action: "delete_reminders", target: summary) {
            return preview
        }

        var deleted: [[String: Any]] = []
        for reminder in reminders {
            guard reminder.calendar.allowsContentModifications, !reminder.calendar.isImmutable else {
                deleted.append([
                    "id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "applied": false,
                    "reason": "list '\(reminder.calendar.title)' is read-only",
                ])
                continue
            }
            let entry: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "list": reminder.calendar.title,
            ]
            do {
                try store.remove(reminder, commit: true)
            } catch {
                throw Self.mapError(error, context: "deleting reminder '\(reminder.title ?? "")'")
            }
            deleted.append(entry)
        }
        return ["applied": true, "deleted": deleted, "count": deleted.count]
    }

    func reminderMoveJSON(_ args: Args) throws -> [String: Any] {
        try requireRead(.reminder)
        try requireWrite(.reminder)
        let ids = try reminderIds(args)
        let target = try resolveContainer(
            id: args.string("list_id") ?? args.string("listId") ?? args.string("calendar_id"),
            title: args.string("list") ?? args.string("calendar") ?? args.string("to_list"),
            entity: .reminder,
            requireWritable: true
        )
        let reminders = try ids.map { try resolveReminder(id: $0) }

        let summary: [String: Any] = [
            "count": reminders.count,
            "to": target.title,
            "from": Array(Set(reminders.map { $0.calendar.title })).sorted(),
        ]
        if case .halt(let preview) = writeGuard(args, action: "move_reminders", target: summary) {
            return preview
        }

        var moved: [[String: Any]] = []
        for reminder in reminders {
            let previous = reminder.calendar.title
            reminder.calendar = target
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw Self.mapError(error, context: "moving reminder '\(reminder.title ?? "")'")
            }
            moved.append([
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "from": previous,
                "to": target.title,
            ])
        }
        return ["applied": true, "moved": moved, "count": moved.count]
    }

    func reminderIds(_ args: Args) throws -> [String] {
        var ids = args.strings("ids")
        if let single = args.string("id") { ids.insert(single, at: 0) }
        ids = ids.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !ids.isEmpty else {
            throw BridgeError.invalid("Pass 'id' or 'ids'.", "Example: {\"ids\": [\"…\", \"…\"]}")
        }
        if ids.count > 200 {
            throw BridgeError.invalid(
                "Refusing to operate on \(ids.count) reminders at once.",
                "Split the request into batches of at most 200."
            )
        }
        return ids
    }

    // MARK: Combined agenda

    /// One call that answers "what is on this day/week", merging calendar events
    /// with due reminders into a single time-ordered timeline.
    func agendaJSON(_ args: Args) throws -> [String: Any] {
        let zone = try Dates.timeZone(args.string("timezone"))
        timeZone = zone
        let range = try Dates.range(from: args, timeZone: zone)
        let includeEvents = args.boolOr("include_events", true)
        let includeReminders = args.boolOr("include_reminders", true)
        let includeCompleted = args.boolOr("include_completed", false)
        let limit = min(max(1, args.intOr("limit", 100)), Env.maxLimit)

        var timeline: [[String: Any]] = []
        var eventCount = 0
        var reminderCount = 0
        var overdueCount = 0
        var warnings: [String] = []

        if includeEvents {
            if Self.canRead(eventAuthorization) {
                let eventArgs = args.merging([
                    "start": Dates.iso(range.start, timeZone: zone),
                    "end": Dates.iso(range.end, timeZone: zone),
                    "limit": limit,
                ])
                if let result = try? eventListJSON(eventArgs, defaultRange: "today"),
                   let events = result["events"] as? [[String: Any]] {
                    for var event in events {
                        event["type"] = "event"
                        event["sortKey"] = (event["start"] as? String) ?? ""
                        timeline.append(event)
                    }
                    eventCount = events.count
                }
            } else {
                warnings.append("Calendar read access is not granted, so events were skipped.")
            }
        }

        if includeReminders {
            if Self.canRead(reminderAuthorization) {
                let reminderArgs = Args([
                    "status": includeCompleted ? "all" : "incomplete",
                    "lists": args.strings("lists"),
                    "limit": Env.maxLimit,
                    "include_details": false,
                    "timezone": zone.identifier,
                ])
                if let result = try? reminderListJSON(reminderArgs),
                   let reminders = result["reminders"] as? [[String: Any]] {
                    for reminder in reminders {
                        guard let due = reminder["due"] as? [String: Any],
                              let dueISO = due["iso"] as? String,
                              let dueDate = try? Dates.parse(dueISO, timeZone: zone).date
                        else { continue }
                        let overdue = due["overdue"] as? Bool ?? false
                        guard (dueDate >= range.start && dueDate < range.end) || overdue else { continue }
                        var item = reminder
                        item["type"] = "reminder"
                        item["sortKey"] = dueISO
                        timeline.append(item)
                        reminderCount += 1
                        if overdue { overdueCount += 1 }
                    }
                }
            } else {
                warnings.append("Reminders read access is not granted, so reminders were skipped.")
            }
        }

        timeline.sort { (($0["sortKey"] as? String) ?? "") < (($1["sortKey"] as? String) ?? "") }
        let trimmed = Array(timeline.prefix(limit))

        var result: [String: Any] = [
            "range": [
                "label": range.label,
                "start": Dates.iso(range.start, timeZone: zone),
                "end": Dates.iso(range.end, timeZone: zone),
                "startLocal": Dates.local(range.start, timeZone: zone),
                "endLocal": Dates.local(range.end, timeZone: zone),
            ],
            "timeZone": zone.identifier,
            "eventCount": eventCount,
            "reminderCount": reminderCount,
            "overdueReminderCount": overdueCount,
            "count": trimmed.count,
            "truncated": timeline.count > trimmed.count,
            "items": trimmed,
        ]
        if !warnings.isEmpty { result["warnings"] = warnings }
        if timeline.isEmpty { result["note"] = "Nothing scheduled in this range." }
        return result
    }
}

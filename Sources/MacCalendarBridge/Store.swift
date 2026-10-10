import CoreLocation
import EventKit
import Foundation

/// Thin, JSON-shaped wrapper over EventKit.
///
/// Everything that talks to EventKit lives here or in the `Events.swift` /
/// `Reminders.swift` extensions. The tool layer above only deals in
/// `[String: Any]`.
final class Store {

    let store: EKEventStore
    var timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.store = EKEventStore()
        self.timeZone = timeZone
    }

    // MARK: - Identifiers

    var defaultEventCalendarId: String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    var defaultReminderListId: String? {
        // `defaultCalendarForNewReminders` is annotated non-null in EventKit's
        // apinotes while `defaultCalendarForNewEvents` stays optional; widen
        // both explicitly so the call sites stay uniform.
        let list: EKCalendar? = store.defaultCalendarForNewReminders()
        return list?.calendarIdentifier
    }

    // MARK: - Permissions

    // `EKAuthorizationStatusAuthorized` is an alias of `.fullAccess`, so these
    // helpers compare instead of switching to avoid duplicate switch branches.
    static func describe(_ status: EKAuthorizationStatus) -> String {
        if status == .notDetermined { return "notDetermined" }
        if status == .restricted { return "restricted" }
        if status == .denied { return "denied" }
        if status == .fullAccess { return "fullAccess" }
        if status == .writeOnly { return "writeOnly" }
        return "unknown(\\(status.rawValue))"
    }

    static func canRead(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess
    }

    static func canWrite(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess || status == .writeOnly
    }

    var eventAuthorization: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var reminderAuthorization: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    /// Human-readable, actionable permission report. This is the first thing an
    /// agent should call when another tool returns `permission_denied`.
    func permissionReport() -> [String: Any] {
        let events = eventAuthorization
        let reminders = reminderAuthorization
        var blockers: [String] = []

        if !Self.canRead(events) {
            blockers.append(
                events == .writeOnly
                    ? "Calendars has 'Add Only' access. Reading calendars and events (and editing container colours) requires Full Access."
                    : "Calendars access is \(Self.describe(events)). Full Access is required to read calendars and events."
            )
        }
        if !Self.canRead(reminders) {
            blockers.append("Reminders access is \(Self.describe(reminders)). Full Access is required.")
        }

        return [
            "calendarAccess": [
                "status": Self.describe(events),
                "canRead": Self.canRead(events),
                "canWrite": Self.canWrite(events),
                "needsFullAccess": !Self.canRead(events),
            ],
            "remindersAccess": [
                "status": Self.describe(reminders),
                "canRead": Self.canRead(reminders),
                "canWrite": Self.canWrite(reminders),
                "needsFullAccess": !Self.canRead(reminders),
            ],
            "ready": blockers.isEmpty,
            "blockers": blockers,
            "responsibleProcessNote": "macOS attributes Calendar/Reminders access to the app that launched this process (Codex, ChatGPT.app, or your terminal), not to the plugin itself. Grant Full Access to that app in System Settings › Privacy & Security.",
            "settingsURLs": [
                "calendars": "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
                "reminders": "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",
            ],
            "remedy": blockers.isEmpty
                ? "No action needed."
                : "A consent dialog is triggered automatically the first time a calendar or reminder operation runs; if it does not appear, macOS has already recorded a decision. Open System Settings › Privacy & Security › Calendars (or Reminders), enable Full Access for the app running Codex, then re-run calendars_status. A rebuild of the helper binary may also invalidate an earlier grant.",
        ]
    }

    /// Triggers the native TCC prompts. Returns the resulting status for both
    /// entity types.
    func requestAccess(events: Bool, reminders: Bool) throws -> [String: Any] {
        var requested: [String] = []

        if events && !Self.canWrite(eventAuthorization) {
            _ = try waitFor { (completion: @escaping (Bool) -> Void) in
                store.requestFullAccessToEvents { granted, _ in completion(granted) }
            }
            requested.append("calendars")
        }
        if reminders && !Self.canWrite(reminderAuthorization) {
            _ = try waitFor { (completion: @escaping (Bool) -> Void) in
                store.requestFullAccessToReminders { granted, _ in completion(granted) }
            }
            requested.append("reminders")
        }

        var report = permissionReport()
        report["requested"] = requested
        report["requestedNothing"] = requested.isEmpty
        return report
    }

    /// Trigger the native consent dialog when access has never been decided.
    ///
    /// TCC attributes the grant to the app that launched this process, so the
    /// first calendar operation under a new host app would otherwise fail with
    /// `notDetermined` and require the caller to know about
    /// `calendars_request_access`. Prompting lazily, exactly when access is first
    /// needed, removes that failure mode.
    ///
    /// Set `MAC_CALENDAR_AUTO_REQUEST_ACCESS=false` to keep the bridge silent for
    /// scripted use.
    func promptIfUndetermined(_ entity: EKEntityType) {
        guard (Env.environment["MAC_CALENDAR_AUTO_REQUEST_ACCESS"] ?? "true").lowercased() != "false" else {
            return
        }
        let status = entity == .event ? eventAuthorization : reminderAuthorization
        guard status == .notDetermined else { return }

        _ = try? waitFor(timeout: 90) { (completion: @escaping (Bool) -> Void) in
            if entity == .event {
                self.store.requestFullAccessToEvents { granted, _ in completion(granted) }
            } else {
                self.store.requestFullAccessToReminders { granted, _ in completion(granted) }
            }
        }
    }

    func requireRead(_ entity: EKEntityType) throws {
        promptIfUndetermined(entity)
        let status = entity == .event ? eventAuthorization : reminderAuthorization
        guard Self.canRead(status) else {
            let name = entity == .event ? "Calendars" : "Reminders"
            throw BridgeError.denied(
                "\(name) access is '\(Self.describe(status))'; read access is not granted to this process.",
                "Grant Full Access to the app running Codex in System Settings › Privacy & Security › \(name), then retry. The consent dialog is triggered automatically on first use; macOS will not show it again once a denial is recorded."
            )
        }
    }

    func requireWrite(_ entity: EKEntityType) throws {
        promptIfUndetermined(entity)
        let status = entity == .event ? eventAuthorization : reminderAuthorization
        guard Self.canWrite(status) else {
            let name = entity == .event ? "Calendars" : "Reminders"
            throw BridgeError.denied(
                "\(name) access is '\(Self.describe(status))'; write access is not granted to this process.",
                "Grant Full Access (or Add Only for events) in System Settings › Privacy & Security › \(name), then retry."
            )
        }
    }

    // MARK: - Accounts / sources

    func sourceDict(_ source: EKSource) -> [String: Any] {
        let eventCount = source.calendars(for: .event).count
        let reminderCount = source.calendars(for: .reminder).count
        return [
            "id": source.sourceIdentifier,
            "title": source.title,
            "type": Self.sourceTypeName(source.sourceType),
            "isDelegate": source.isDelegate,
            "eventCalendarCount": eventCount,
            "reminderListCount": reminderCount,
        ]
    }

    static func sourceTypeName(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "other"
        }
    }

    func sources() -> [EKSource] {
        store.sources.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Containers (calendars and reminder lists)

    func calendars(for entity: EKEntityType) -> [EKCalendar] {
        store.calendars(for: entity).sorted {
            if $0.source.title != $1.source.title {
                return $0.source.title.localizedStandardCompare($1.source.title) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func calendarTypeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "calDAV"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "other"
        }
    }

    func containerDict(_ calendar: EKCalendar) -> [String: Any] {
        let supportsEvents = calendar.allowedEntityTypes.contains(.event)
        let supportsReminders = calendar.allowedEntityTypes.contains(.reminder)
        let isDefault = calendar.calendarIdentifier == defaultEventCalendarId
            || calendar.calendarIdentifier == defaultReminderListId
        var entry: [String: Any] = [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "kind": supportsEvents && supportsReminders ? "mixed" : (supportsReminders ? "reminderList" : "calendar"),
            "account": calendar.source.title,
            "accountId": calendar.source.sourceIdentifier,
            "accountType": Self.sourceTypeName(calendar.source.sourceType),
            "calendarType": Self.calendarTypeName(calendar.type),
            "isDefault": isDefault,
            "isImmutable": calendar.isImmutable,
            "isSubscribed": calendar.isSubscribed,
            "allowsContentModifications": calendar.allowsContentModifications,
            "isWritable": calendar.allowsContentModifications && !calendar.isImmutable && !calendar.isSubscribed,
            "supportedEventAvailabilities": Self.availabilityNames(calendar.supportedEventAvailabilities),
        ]
        if let hex = Colors.hex(calendar.color) {
            entry["colorHex"] = hex
        } else {
            entry["colorHex"] = NSNull()
        }
        if calendar.calendarIdentifier == defaultEventCalendarId { entry["isDefaultForEvents"] = true }
        if calendar.calendarIdentifier == defaultReminderListId { entry["isDefaultForReminders"] = true }
        return entry
    }

    static func availabilityNames(_ mask: EKCalendarEventAvailabilityMask) -> [String] {
        var names: [String] = []
        if mask.contains(.busy) { names.append("busy") }
        if mask.contains(.free) { names.append("free") }
        if mask.contains(.tentative) { names.append("tentative") }
        if mask.contains(.unavailable) { names.append("unavailable") }
        return names
    }

    func listContainers(entity: EKEntityType, account: String? = nil, writableOnly: Bool = false) -> [String: Any] {
        var containers = calendars(for: entity)
        if let account, !account.isEmpty {
            let needle = account.lowercased()
            containers = containers.filter {
                $0.source.title.lowercased() == needle
                    || $0.source.sourceIdentifier == account
                    || $0.source.title.lowercased().contains(needle)
            }
        }
        if writableOnly {
            containers = containers.filter { $0.allowsContentModifications && !$0.isImmutable && !$0.isSubscribed }
        }
        return [
            "entity": entity == .event ? "event" : "reminder",
            "count": containers.count,
            "containers": containers.map(containerDict),
        ]
    }

    /// Resolve a container by id or title.
    ///
    /// Ambiguity is a hard error rather than a guess: silently writing into the
    /// wrong calendar is the worst failure mode of this tool.
    func resolveContainer(
        id: String?,
        title: String?,
        entity: EKEntityType,
        requireWritable: Bool = false
    ) throws -> EKCalendar {
        let candidates = calendars(for: entity)

        if let id, !id.isEmpty {
            if let match = candidates.first(where: { $0.calendarIdentifier == id }) {
                try checkWritable(match, requireWritable: requireWritable)
                return match
            }
            if let any = store.calendar(withIdentifier: id) {
                // Exists, but for the other entity type.
                let kind = entity == .event ? "calendar" : "reminder list"
                throw BridgeError.invalid(
                    "'\(any.title)' is not a \(kind).",
                    "Its allowed entity types are \(Self.allowedEntityNames(any.allowedEntityTypes))."
                )
            }
            throw BridgeError.notFound(
                "No \(entity == .event ? "calendar" : "reminder list") with id '\(id)'.",
                "Use \(entity == .event ? "calendar_list_calendars" : "reminders_list_lists") to get valid ids."
            )
        }

        return try resolveByName(title, entity: entity, requireWritable: requireWritable)
    }

    /// Resolve a single caller-supplied target that may be either an identifier or
    /// a name. Filter arguments such as `calendars: ["工作"]` accept both forms,
    /// so the two lookups are chained here instead of at every call site.
    func resolveTarget(_ value: String, entity: EKEntityType, requireWritable: Bool = false) throws -> EKCalendar {
        if let match = calendars(for: entity).first(where: { $0.calendarIdentifier == value }) {
            try checkWritable(match, requireWritable: requireWritable)
            return match
        }
        return try resolveByName(value, entity: entity, requireWritable: requireWritable)
    }

    private func resolveByName(
        _ title: String?,
        entity: EKEntityType,
        requireWritable: Bool
    ) throws -> EKCalendar {
        let candidates = calendars(for: entity)
        let kind = entity == .event ? "calendar" : "reminder list"

        if let title, !title.isEmpty {
            let exact = candidates.filter { $0.title == title }
            let loose = exact.isEmpty
                ? candidates.filter { $0.title.lowercased() == title.lowercased() }
                : exact
            let fuzzy = loose.isEmpty
                ? candidates.filter { $0.title.lowercased().contains(title.lowercased()) }
                : loose
            if fuzzy.count == 1 {
                try checkWritable(fuzzy[0], requireWritable: requireWritable)
                return fuzzy[0]
            }
            if fuzzy.count > 1 {
                throw BridgeError.ambiguous(
                    "Several \(kind)s match '\(title)': \(fuzzy.map { "\($0.title) [\($0.source.title)]" }.joined(separator: ", ")).",
                    "Pass an explicit id to disambiguate."
                )
            }
            let available = candidates.map { $0.title }.joined(separator: ", ")
            throw BridgeError.notFound(
                "No \(kind) named '\(title)'.",
                available.isEmpty ? "No containers exist yet." : "Available: \(available)."
            )
        }

        // Fall back to the bridge's pinned default, then the system default.
        var fallback: EKCalendar? = nil
        if let pinnedId = Preferences.defaultContainerId(entity: entity) {
            fallback = store.calendar(withIdentifier: pinnedId)
        }
        if fallback == nil {
            let eventDefault: EKCalendar? = store.defaultCalendarForNewEvents
            let reminderDefault: EKCalendar? = store.defaultCalendarForNewReminders()
            fallback = entity == .event ? eventDefault : reminderDefault
        }
        guard let fallback else {
            throw BridgeError.notFound(
                "No default \(entity == .event ? "calendar" : "reminder list") is configured.",
                "Pass 'calendar' (name) or 'calendar_id' explicitly."
            )
        }
        try checkWritable(fallback, requireWritable: requireWritable)
        return fallback
    }

    static func allowedEntityNames(_ mask: EKEntityMask) -> String {
        var names: [String] = []
        if mask.contains(.event) { names.append("event") }
        if mask.contains(.reminder) { names.append("reminder") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    private func checkWritable(_ calendar: EKCalendar, requireWritable: Bool) throws {
        guard requireWritable else { return }
        if calendar.isImmutable {
            throw BridgeError.unsupported(
                "'\(calendar.title)' is immutable (read-only).",
                "Holiday, birthday, and subscribed calendars cannot be modified. Choose another container."
            )
        }
        if calendar.isSubscribed {
            throw BridgeError.unsupported(
                "'\(calendar.title)' is a subscription calendar.",
                "Subscribed calendars are read-only. Choose another container."
            )
        }
        guard calendar.allowsContentModifications else {
            throw BridgeError.unsupported(
                "'\(calendar.title)' does not allow content modifications.",
                "This is common for shared or read-only calendars. Choose another container."
            )
        }
    }

    // MARK: - Container mutations

    /// Create a calendar or reminder list.
    ///
    /// Several accounts can share a title (this machine has two sources called
    /// 'iCloud', one for calendars and one for reminders), and an account may not
    /// support the requested entity type. Rather than guessing, every plausible
    /// source is tried in order and the first successful save wins.
    func createContainer(
        entity: EKEntityType,
        title: String,
        colorHex: String?,
        account: String?
    ) throws -> EKCalendar {
        let usable = sources().filter { $0.sourceType != .birthdays && $0.sourceType != .subscribed }
        guard !usable.isEmpty else {
            throw BridgeError.failed(
                "No writable account is available to create a container in.",
                "Add an iCloud, Google, Exchange, or local account in Calendar.app first."
            )
        }

        let candidates: [EKSource]
        if let account, !account.isEmpty {
            let needle = account.lowercased()
            let matched = usable.filter {
                $0.sourceIdentifier == account
                    || $0.title.lowercased() == needle
                    || $0.title.lowercased().contains(needle)
            }
            guard !matched.isEmpty else {
                throw BridgeError.notFound(
                    "No account matching '\(account)'.",
                    "Available accounts: \(usable.map { "\($0.title) [\(Self.sourceTypeName($0.sourceType))]" }.joined(separator: ", "))."
                )
            }
            candidates = matched
        } else {
            candidates = usable.sorted { Self.sourceRank($0) < Self.sourceRank($1) }
        }

        let color = try colorHex.map { try Colors.color($0) }
        var failures: [String] = []
        for source in candidates {
            let calendar = EKCalendar(for: entity, eventStore: store)
            calendar.title = title
            if let color { calendar.color = color }
            calendar.source = source
            do {
                try saveCalendar(calendar)
                return calendar
            } catch let bridgeError as BridgeError {
                failures.append("\(source.title) [\(Self.sourceTypeName(source.sourceType))]: \(bridgeError.message)")
            } catch {
                failures.append("\(source.title) [\(Self.sourceTypeName(source.sourceType))]: \(error.localizedDescription)")
            }
        }

        throw BridgeError.failed(
            "Could not create the \(entity == .event ? "calendar" : "reminder list") in any candidate account.",
            "Tried \(failures.joined(separator: "; ")). Most commonly the account does not support \(entity == .event ? "calendars" : "reminders") — pick another account."
        )
    }

    /// Preference order when no account is given: syncing accounts first, local last.
    static func sourceRank(_ source: EKSource) -> Int {
        switch source.sourceType {
        case .mobileMe: return 0
        case .calDAV: return 1
        case .exchange: return 2
        case .local: return 3
        case .subscribed: return 4
        case .birthdays: return 5
        @unknown default: return 6
        }
    }

    private func saveCalendar(_ calendar: EKCalendar) throws {
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw Self.mapError(error, context: "saving the container")
        }
    }

    func updateContainer(
        _ calendar: EKCalendar,
        newTitle: String?,
        newColorHex: String?
    ) throws -> EKCalendar {
        if let newTitle, !newTitle.isEmpty {
            calendar.title = newTitle
        }
        if let newColorHex, !newColorHex.isEmpty {
            calendar.color = try Colors.color(newColorHex)
        }
        try saveCalendar(calendar)
        return calendar
    }

    func deleteContainer(_ calendar: EKCalendar) throws {
        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            throw Self.mapError(error, context: "removing the container")
        }
    }

    /// How much would be destroyed by deleting this container? Used to force an
    /// explicit acknowledgement before a destructive delete.
    func containerItemCounts(_ calendar: EKCalendar) -> [String: Any] {
        var result: [String: Any] = [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "account": calendar.source.title,
        ]
        if calendar.allowedEntityTypes.contains(.event) {
            let now = Date()
            let start = now.addingTimeInterval(-86_400 * 365 * 2)
            let end = now.addingTimeInterval(86_400 * 365 * 5)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            let events = store.events(matching: predicate)
            result["eventCount"] = events.count
            result["eventCountWindow"] = "two years back to five years ahead"
            result["eventCountIsApproximate"] = true
        }
        if calendar.allowedEntityTypes.contains(.reminder) {
            let reminders = (try? fetchReminders(in: [calendar])) ?? []
            result["reminderCount"] = reminders.count
        }
        return result
    }

    // MARK: - Reminder fetching primitive

    func fetchReminders(in calendars: [EKCalendar]?) throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: calendars)
        return try waitFor { (completion: @escaping ([EKReminder]) -> Void) in
            self.store.fetchReminders(matching: predicate) { reminders in
                completion(reminders ?? [])
            }
        }
    }

    // MARK: - Misc helpers

    static func urgencyLabel(_ priority: Int) -> String {
        switch priority {
        case 0: return "none"
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return "none"
        }
    }

    static func priority(from value: String?) throws -> Int {
        guard let value, !value.isEmpty else { return 0 }
        if let number = Int(value) {
            guard (0...9).contains(number) else {
                throw BridgeError.invalid("priority must be between 0 and 9.", nil)
            }
            return number
        }
        switch value.lowercased() {
        case "none", "无": return 0
        case "high", "高": return 1
        case "medium", "med", "中": return 5
        case "low", "低": return 9
        default:
            throw BridgeError.invalid("Unknown priority '\(value)'.", "Use none, low, medium, high, or an integer 0-9.")
        }
    }

    static func availabilityName(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        case .notSupported: return "notSupported"
        @unknown default: return "unsupported"
        }
    }

    static func availability(from value: String) throws -> EKEventAvailability {
        switch value.lowercased() {
        case "busy", "忙": return .busy
        case "free", "空闲": return .free
        case "tentative", "暂定": return .tentative
        case "unavailable", "outofoffice", "out_of_office", "不在": return .unavailable
        default:
            throw BridgeError.invalid("Unknown availability '\(value)'.", "Use busy, free, tentative, or unavailable.")
        }
    }

    static func statusName(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    static func span(from value: String?) throws -> EKSpan {
        switch (value ?? "this").lowercased() {
        case "this", "this_event", "single", "occurrence": return .thisEvent
        case "future", "this_and_future", "following": return .futureEvents
        case "all", "series", "entire": return .futureEvents
        default:
            throw BridgeError.invalid(
                "Unknown span '\(value ?? "")'.",
                "Use 'this' for a single occurrence, 'this_and_future' or 'all' for the whole series."
            )
        }
    }

    static func proximity(from value: String) throws -> EKAlarmProximity {
        switch value.lowercased() {
        case "enter", "arrive", "到达": return .enter
        case "leave", "depart", "离开": return .leave
        case "none": return .none
        default:
            throw BridgeError.invalid("Unknown proximity '\(value)'.", "Use enter, leave, or none.")
        }
    }

    static func mapError(_ error: Error, context: String) -> BridgeError {
        let nsError = error as NSError
        let message = "EventKit failed while \(context): \(nsError.localizedDescription)"
        guard nsError.domain == EKErrorDomain, let code = EKError.Code(rawValue: nsError.code) else {
            return .failed(message, nil)
        }
        switch code {
        case .eventNotMutable, .calendarReadOnly, .calendarIsImmutable,
             .calendarDoesNotAllowEvents, .calendarDoesNotAllowReminders:
            return .unsupported(
                message,
                "The target container is read-only or does not accept this kind of item. Pick a writable calendar or reminder list."
            )
        case .sourceDoesNotAllowCalendarAddDelete, .calendarSourceCannotBeModified:
            return .unsupported(
                message,
                "That account does not allow creating or removing containers. Try a different account, for example iCloud or a local one."
            )
        case .noCalendar, .calendarHasNoSource:
            return .invalid(message, "The target calendar or list could not be resolved.")
        case .noStartDate, .noEndDate, .datesInverted:
            return .invalid(message, "Provide both a start and an end, with the end after the start.")
        case .priorityIsInvalid:
            return .invalid(message, "Priority must be an integer from 0 to 9.")
        case .recurringReminderRequiresDueDate:
            return .invalid(message, "A recurring reminder needs a due date.")
        case .startDateTooFarInFuture, .startDateCollidesWithOtherOccurrence,
             .durationGreaterThanRecurrence, .alarmGreaterThanRecurrence:
            return .invalid(message, "Adjust the start time, duration, or recurrence so the series is consistent.")
        case .structuredLocationsNotSupported, .reminderLocationsNotSupported, .alarmProximityNotSupported:
            return .unsupported(
                message,
                "This account does not support location-based alarms. Create the item in an iCloud or local container instead."
            )
        case .invitesCannotBeMoved:
            return .unsupported(message, "Invitations cannot be moved between calendars.")
        case .eventStoreNotAuthorized:
            return .denied(message, "Grant Full Access in System Settings › Privacy & Security, then retry.")
        case .procedureAlarmsNotMutable:
            return .unsupported(message, nil)
        default:
            return .failed(message, nil)
        }
    }
}

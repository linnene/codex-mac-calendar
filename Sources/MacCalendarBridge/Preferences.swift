import EventKit
import Foundation

/// Local, non-EventKit preferences.
///
/// macOS exposes no API to change the system default calendar or reminder list,
/// so the bridge keeps its own pin and uses it whenever a tool is called without
/// an explicit container.
enum Preferences {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("mac-calendar-bridge", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("preferences.json") }

    struct Values {
        var eventCalendarId: String?
        var reminderListId: String?
        var timeZoneIdentifier: String?
    }

    static func load() -> Values {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Values(eventCalendarId: nil, reminderListId: nil, timeZoneIdentifier: nil)
        }
        return Values(
            eventCalendarId: object["defaultEventCalendarId"] as? String,
            reminderListId: object["defaultReminderListId"] as? String,
            timeZoneIdentifier: object["timeZone"] as? String
        )
    }

    static func defaultContainerId(entity: EKEntityType) -> String? {
        let values = load()
        return entity == .event ? values.eventCalendarId : values.reminderListId
    }

    static func save(
        eventCalendarId: String?,
        reminderListId: String?,
        timeZoneIdentifier: String?
    ) throws {
        var current = load()
        if let eventCalendarId { current.eventCalendarId = eventCalendarId }
        if let reminderListId { current.reminderListId = reminderListId }
        if let timeZoneIdentifier { current.timeZoneIdentifier = timeZoneIdentifier }

        var object: [String: Any] = [:]
        if let value = current.eventCalendarId { object["defaultEventCalendarId"] = value }
        if let value = current.reminderListId { object["defaultReminderListId"] = value }
        if let value = current.timeZoneIdentifier { object["timeZone"] = value }
        object["updatedAt"] = Dates.iso(Date(), timeZone: .current)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw BridgeError.failed(
                "Could not write \(fileURL.path): \(error.localizedDescription)",
                "Check that the directory is writable."
            )
        }
    }

    static func clear(entity: EKEntityType) throws {
        var current = load()
        if entity == .event { current.eventCalendarId = nil } else { current.reminderListId = nil }
        var object: [String: Any] = [:]
        if let value = current.eventCalendarId { object["defaultEventCalendarId"] = value }
        if let value = current.reminderListId { object["defaultReminderListId"] = value }
        if let value = current.timeZoneIdentifier { object["timeZone"] = value }
        object["updatedAt"] = Dates.iso(Date(), timeZone: .current)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }
}

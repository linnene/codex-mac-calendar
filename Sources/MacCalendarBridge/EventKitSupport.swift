import EventKit
import Foundation

/// EventKit declares several properties `null_unspecified`, which Swift surfaces
/// as plain optionals even though EventKit guarantees values for stored items.
/// These accessors keep the JSON layer total and the call sites readable.
extension EKEvent {
    var safeStart: Date { startDate ?? Date() }
    var safeEnd: Date { endDate ?? startDate ?? Date() }
    var safeOccurrence: Date? { occurrenceDate }
    /// `eventIdentifier` is `null_unspecified`, so it must be unwrapped before it
    /// can be stored in a `[String: Any]` that has to survive JSON encoding.
    var safeIdentifier: String { eventIdentifier ?? "" }
}

extension EKCalendarItem {
    var safeTitle: String { title ?? "" }
}

extension EKEvent {
    /// Set the schedule in the only order EventKit accepts.
    ///
    /// EventKit reinterprets `startDate`/`endDate` whenever `isAllDay` or
    /// `timeZone` changes afterwards, and attaching a time zone to an all-day event
    /// makes it silently drop the all-day flag — the event keeps its midnight start
    /// and stops being an all-day event at all. Every write path funnels through
    /// here so the ordering cannot drift between call sites again.
    func applySchedule(isAllDay: Bool, timeZone: TimeZone?, start: Date, end: Date) {
        self.isAllDay = isAllDay
        // An all-day event is time-zone independent by definition, so a zone is
        // never attached to one.
        self.timeZone = isAllDay ? nil : timeZone
        self.startDate = start
        self.endDate = end
    }
}

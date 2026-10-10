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

import Foundation

/// Flexible date parsing and stable, agent-readable date rendering.
///
/// Accepted inputs, in the order they are tried:
/// explicit ISO-8601 (with or without zone), `yyyy-MM-dd` style calendar
/// formats, `HH:mm` clock times, relative offsets (`+90m`, `in 2 hours`,
/// `3 天后`), day keywords (`today`, `明天`), and weekday references
/// (`monday`, `下周三 15:00`).
enum Dates {

    // MARK: Formatting

    static func iso(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }

    /// `2026-10-10 15:00 Sat` — unambiguous for both humans and models.
    static func local(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEE"
        return formatter.string(from: date)
    }

    static func dateOnly(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func stamp(_ date: Date?, timeZone: TimeZone) -> Any {
        guard let date else { return NSNull() }
        return [
            "iso": iso(date, timeZone: timeZone),
            "local": local(date, timeZone: timeZone),
            "epochSeconds": Int(date.timeIntervalSince1970),
            "timeZone": timeZone.identifier,
        ]
    }

    static func offset(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let sign = minutes < 0 ? "-" : "+"
        let magnitude = abs(minutes)
        return "\(sign)\(magnitude / 60):\(String(format: "%02d", magnitude % 60))"
    }

    /// Human description of an alarm offset, e.g. `15 minutes before`.
    static func describeOffset(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total == 0 { return "at start time" }
        let past = total < 0
        let magnitude = abs(total)
        let units: [(String, Int)] = [
            ("day", 86_400), ("hour", 3_600), ("minute", 60), ("second", 1),
        ]
        for (name, size) in units where magnitude >= size && magnitude % size == 0 {
            let count = magnitude / size
            let label = count == 1 ? name : name + "s"
            return "\(count) \(label) \(past ? "before" : "after")"
        }
        return "\(magnitude) seconds \(past ? "before" : "after")"
    }

    // MARK: Parsing

    struct Parsed {
        var date: Date
        var isDateOnly: Bool
        /// Original substring that produced the value, when known.
        var matchedText: String?
    }

    static func timeZone(_ identifier: String?) throws -> TimeZone {
        guard let identifier, !identifier.isEmpty else { return .current }
        guard let zone = TimeZone(identifier: identifier) else {
            throw BridgeError.invalid("Unknown time zone '\(identifier)'.", "Use an IANA name such as 'Asia/Shanghai'.")
        }
        return zone
    }

    static func parse(_ input: String, now: Date = Date(), timeZone: TimeZone = .current, futureBias: Bool = false) throws -> Parsed {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw BridgeError.invalid("Empty date string.", nil)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let lower = text.lowercased()

        if lower == "now" || lower == "现在" {
            return Parsed(date: now, isDateOnly: false, matchedText: text)
        }

        if let parsed = parseExplicit(text, calendar: calendar, timeZone: timeZone, now: now) {
            return parsed
        }

        if let parsed = parseRelative(lower, calendar: calendar, now: now) {
            return parsed
        }

        if let parsed = parseDayKeyword(lower, calendar: calendar, timeZone: timeZone, now: now) {
            return parsed
        }

        if let parsed = parseWeekday(text, calendar: calendar, timeZone: timeZone, now: now) {
            return parsed
        }

        if let parsed = parseClock(text, calendar: calendar, now: now, futureBias: futureBias) {
            return parsed
        }

        throw BridgeError.invalid(
            "Could not understand the date '\(input)'.",
            "Use ISO-8601 ('2026-10-10T15:00:00+08:00'), a date ('2026-10-10'), a clock time ('15:00'), a relative offset ('+90m', 'in 2 hours', '3 天后'), or a day/weekday word ('tomorrow', '下周三 15:00')."
        )
    }

    private static func parseExplicit(_ text: String, calendar: Calendar, timeZone: TimeZone, now: Date) -> Parsed? {
        let candidates: [(String, Bool)] = [
            ("yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", false),
            ("yyyy-MM-dd'T'HH:mm:ssXXXXX", false),
            ("yyyy-MM-dd'T'HH:mm:ssZ", false),
            ("yyyy-MM-dd'T'HH:mm:ss", false),
            ("yyyy-MM-dd'T'HH:mm", false),
            ("yyyy-MM-dd HH:mm:ss", false),
            ("yyyy-MM-dd HH:mm", false),
            ("yyyy-MM-dd HH:mm:ss Z", false),
            ("yyyy-MM-dd", true),
            ("yyyy/MM/dd HH:mm", false),
            ("yyyy/MM/dd", true),
            ("yyyy.MM.dd", true),
            ("yyyy年M月d日 HH:mm", false),
            ("yyyy年M月d日", true),
        ]
        for (format, isDateOnly) in candidates {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: text) {
                return Parsed(date: date, isDateOnly: isDateOnly, matchedText: text)
            }
        }
        // Bare "MM-dd" or "MM/dd" resolves against the current year.
        for format in ["MM-dd HH:mm", "MM-dd", "MM/dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatter.defaultDate = now
            if let date = formatter.date(from: text) {
                return Parsed(date: date, isDateOnly: !format.contains("HH"), matchedText: text)
            }
        }
        return nil
    }

    private static func parseRelative(_ lower: String, calendar: Calendar, now: Date) -> Parsed? {
        let compact = lower.replacingOccurrences(of: " ", with: "")

        // +90m / -2h / +3d
        if let match = firstMatch(#"^([+-])(\d+(?:\.\d+)?)([smhdw])$"#, in: compact),
           match.groups.count >= 3,
           let amount = Double(match.groups[1]),
           let unit = unitSeconds(match.groups[2]) {
            let sign = match.groups[0] == "-" ? -1.0 : 1.0
            return Parsed(date: now.addingTimeInterval(sign * amount * unit), isDateOnly: false, matchedText: lower)
        }

        // in 2 hours / 2 hours from now
        if let match = firstMatch(#"^(?:in\s*)?(\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w)(?:\s*from\s*now)?$"#, in: lower),
           match.groups.count >= 2,
           let amount = Double(match.groups[0]),
           let unit = unitSeconds(match.groups[1].prefix(1).description) {
            return Parsed(date: now.addingTimeInterval(amount * unit), isDateOnly: false, matchedText: lower)
        }

        // 3天后 / 2小时后 / 30分钟后 / 1周后
        if let match = firstMatch(#"^(\d+(?:\.\d+)?)\s*(分钟|分|小时|钟头|天|日|周|个?星期|个?月)后$"#, in: compact),
           match.groups.count >= 2,
           let amount = Double(match.groups[0]) {
            let unit: Double?
            switch match.groups[1] {
            case "分钟", "分": unit = 60
            case "小时", "钟头": unit = 3_600
            case "天", "日": unit = 86_400
            case "周", "星期", "个星期": unit = 604_800
            case "月", "个月": unit = 2_592_000
            default: unit = nil
            }
            guard let seconds = unit else { return nil }
            return Parsed(date: now.addingTimeInterval(amount * seconds), isDateOnly: false, matchedText: lower)
        }

        return nil
    }

    private static func parseDayKeyword(_ lower: String, calendar: Calendar, timeZone: TimeZone, now: Date) -> Parsed? {
        // Allow an optional trailing clock time: "tomorrow 15:00", "明天下午3点".
        let dayOffsets: [(String, Int)] = [
            ("today", 0), ("今天", 0), ("今日", 0),
            ("tomorrow", 1), ("明天", 1), ("明日", 1),
            ("day after tomorrow", 2), ("后天", 2),
            ("yesterday", -1), ("昨天", -1), ("昨日", -1),
            ("前天", -2),
        ]
        for (keyword, offset) in dayOffsets {
            guard lower == keyword || lower.hasPrefix(keyword + " ") || lower.hasPrefix(keyword + "，") || lower.hasPrefix(keyword + ",") || lower.hasPrefix(keyword) && lower.count > keyword.count else {
                continue
            }
            guard let base = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { return nil }
            let remainder = String(lower.dropFirst(keyword.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,，。")).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                return Parsed(date: base, isDateOnly: true, matchedText: keyword)
            }
            if let clock = parseClock(remainder, calendar: calendar, now: now, futureBias: false, baseDay: base) {
                return Parsed(date: clock.date, isDateOnly: false, matchedText: lower)
            }
            return nil
        }
        _ = timeZone
        return nil
    }

    private static func parseWeekday(_ text: String, calendar: Calendar, timeZone: TimeZone, now: Date) -> Parsed? {
        let lower = text.lowercased()
        let names: [(String, Int)] = [
            ("sunday", 1), ("sun", 1), ("周日", 1), ("星期日", 1), ("星期天", 1),
            ("monday", 2), ("mon", 2), ("周一", 2), ("星期一", 2),
            ("tuesday", 3), ("tue", 3), ("周二", 3), ("星期二", 3),
            ("wednesday", 4), ("wed", 4), ("周三", 4), ("星期三", 4),
            ("thursday", 5), ("thu", 5), ("周四", 5), ("星期四", 5),
            ("friday", 6), ("fri", 6), ("周五", 6), ("星期五", 6),
            ("saturday", 7), ("sat", 7), ("周六", 7), ("星期六", 7),
        ]

        // Weeks are resolved with ISO semantics (Monday first) so that 'next
        // monday' and '下周三' behave the same regardless of the machine locale.
        var iso = calendar
        iso.firstWeekday = 2
        iso.minimumDaysInFirstWeek = 4

        for (name, weekday) in names {
            guard let range = lower.range(of: name) else { continue }
            let prefix = String(lower[lower.startIndex..<range.lowerBound])
            let suffix = String(lower[range.upperBound...])
            let matched = String(text[range.lowerBound..<range.upperBound])

            var weekOffset = 0
            var weekWasExplicit = false
            if prefix.contains("next") || prefix.contains("下") {
                weekOffset = 1
                weekWasExplicit = true
            } else if prefix.contains("last") || prefix.contains("上") {
                weekOffset = -1
                weekWasExplicit = true
            }

            guard let weekStart = iso.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }
            let indexInWeek = weekday == 1 ? 6 : weekday - 2
            var day = iso.date(byAdding: .day, value: weekOffset * 7 + indexInWeek, to: weekStart) ?? weekStart
            if !weekWasExplicit, day < iso.startOfDay(for: now) {
                day = iso.date(byAdding: .day, value: 7, to: day) ?? day
            }

            let clockText = suffix
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,，。"))
                .trimmingCharacters(in: .whitespaces)
            if clockText.isEmpty {
                return Parsed(date: day, isDateOnly: true, matchedText: matched)
            }
            if let clock = parseClock(clockText, calendar: iso, now: now, futureBias: false, baseDay: day) {
                return Parsed(date: clock.date, isDateOnly: false, matchedText: text)
            }
            return Parsed(date: day, isDateOnly: true, matchedText: matched)
        }
        return nil
    }

    private static func parseClock(_ text: String, calendar: Calendar, now: Date, futureBias: Bool, baseDay: Date? = nil) -> Parsed? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var afternoon = false
        var evening = false
        if value.contains("下午") || value.lowercased().contains("pm") { afternoon = true }
        if value.contains("晚上") || value.contains("傍晚") { evening = true; afternoon = true }
        if value.contains("上午") || value.contains("早上") || value.lowercased().contains("am") { afternoon = false }
        value = value.replacingOccurrences(of: "下午", with: "")
            .replacingOccurrences(of: "上午", with: "")
            .replacingOccurrences(of: "早上", with: "")
            .replacingOccurrences(of: "晚上", with: "")
            .replacingOccurrences(of: "傍晚", with: "")
            .lowercased()
            .replacingOccurrences(of: "am", with: "")
            .replacingOccurrences(of: "pm", with: "")
            .replacingOccurrences(of: "点", with: ":")
            .replacingOccurrences(of: "时", with: ":")
            .replacingOccurrences(of: "分", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let match = firstMatch(#"^(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?$"#, in: value) else { return nil }
        guard var hour = Int(match.groups[0]) else { return nil }
        let minute = Int(match.groups[1]) ?? 0
        let second = Int(match.groups[2]) ?? 0
        guard hour >= 0, hour <= 23 || (afternoon && hour <= 12) else { return nil }
        if afternoon && hour < 12 { hour += 12 }
        if evening && hour < 12 { hour = hour == 12 ? 12 : hour + 12 }

        let day = baseDay ?? calendar.startOfDay(for: now)
        guard var date = calendar.date(bySettingHour: hour, minute: minute, second: second, of: day) else { return nil }
        if baseDay == nil && futureBias && date < now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return Parsed(date: date, isDateOnly: false, matchedText: text)
    }

    private static func unitSeconds(_ raw: String) -> Double? {
        switch raw.lowercased().prefix(1) {
        case "s": return 1
        case "m": return 60
        case "h": return 3_600
        case "d": return 86_400
        case "w": return 604_800
        default: return nil
        }
    }

    // MARK: Presets

    struct Range {
        var start: Date
        var end: Date
        var label: String
    }

    static let presetNames = [
        "today", "tomorrow", "yesterday", "day_after_tomorrow",
        "this_week", "next_week", "last_week", "weekend",
        "this_month", "next_month", "this_year",
        "next_7_days", "next_14_days", "next_30_days",
        "last_7_days", "last_30_days",
    ]

    static func preset(_ name: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Range {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")

        func days(_ from: Date, _ count: Int, _ label: String) -> Range {
            let start = calendar.startOfDay(for: from)
            let end = calendar.date(byAdding: .day, value: count, to: start) ?? start
            return Range(start: start, end: end, label: label)
        }

        switch key {
        case "today": return days(now, 1, "today")
        case "tomorrow":
            let base = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return days(base, 1, "tomorrow")
        case "yesterday":
            let base = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return days(base, 1, "yesterday")
        case "day_after_tomorrow":
            let base = calendar.date(byAdding: .day, value: 2, to: now) ?? now
            return days(base, 1, "day after tomorrow")
        case "this_week":
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
                throw BridgeError.failed("Could not compute the current week.", nil)
            }
            return Range(start: interval.start, end: interval.end, label: "this week")
        case "next_week":
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
                throw BridgeError.failed("Could not compute next week.", nil)
            }
            let start = calendar.date(byAdding: .weekOfYear, value: 1, to: interval.start) ?? interval.start
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: interval.end) ?? interval.end
            return Range(start: start, end: end, label: "next week")
        case "last_week":
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
                throw BridgeError.failed("Could not compute last week.", nil)
            }
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start) ?? interval.start
            let end = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.end) ?? interval.end
            return Range(start: start, end: end, label: "last week")
        case "weekend":
            let weekday = calendar.component(.weekday, from: now)
            let isSaturday = weekday == 7
            let offsetToSaturday = isSaturday ? 0 : (7 - weekday)
            let saturday = calendar.date(byAdding: .day, value: offsetToSaturday, to: calendar.startOfDay(for: now)) ?? now
            return days(saturday, 2, "weekend")
        case "this_month":
            guard let interval = calendar.dateInterval(of: .month, for: now) else {
                throw BridgeError.failed("Could not compute the current month.", nil)
            }
            return Range(start: interval.start, end: interval.end, label: "this month")
        case "next_month":
            guard let interval = calendar.dateInterval(of: .month, for: now) else {
                throw BridgeError.failed("Could not compute next month.", nil)
            }
            let start = calendar.date(byAdding: .month, value: 1, to: interval.start) ?? interval.start
            let end = calendar.date(byAdding: .month, value: 1, to: interval.end) ?? interval.end
            return Range(start: start, end: end, label: "next month")
        case "this_year":
            guard let interval = calendar.dateInterval(of: .year, for: now) else {
                throw BridgeError.failed("Could not compute the current year.", nil)
            }
            return Range(start: interval.start, end: interval.end, label: "this year")
        case "next_7_days": return days(now, 7, "next 7 days")
        case "next_14_days": return days(now, 14, "next 14 days")
        case "next_30_days": return days(now, 30, "next 30 days")
        case "last_7_days":
            let base = calendar.date(byAdding: .day, value: -6, to: now) ?? now
            return days(base, 7, "last 7 days")
        case "last_30_days":
            let base = calendar.date(byAdding: .day, value: -29, to: now) ?? now
            return days(base, 30, "last 30 days")
        default:
            throw BridgeError.invalid(
                "Unknown range preset '\(name)'.",
                "Valid presets: \(presetNames.joined(separator: ", ")), or pass explicit 'start' and 'end'."
            )
        }
    }

    /// Resolve a range from either `range: "<preset>"` or `start`/`end`.
    static func range(from args: Args, timeZone: TimeZone, now: Date = Date()) throws -> Range {
        if let startText = args.string("start") {
            let start = try parse(startText, now: now, timeZone: timeZone).date
            let endText = args.string("end")
            let end: Date
            if let endText {
                end = try parse(endText, now: now, timeZone: timeZone).date
            } else if let days = args.int("days") {
                end = start.addingTimeInterval(Double(days) * 86_400)
            } else {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            }
            guard end > start else {
                throw BridgeError.invalid("'end' must be after 'start'.", nil)
            }
            return Range(start: start, end: end, label: "\(iso(start, timeZone: timeZone)) → \(iso(end, timeZone: timeZone))")
        }
        let presetName = args.string("range") ?? args.string("preset") ?? "today"
        return try preset(presetName, now: now, timeZone: timeZone)
    }

    // MARK: Regex helper

    struct Match {
        /// The entire matched substring.
        let full: String
        /// One entry per parenthesised capture group; unmatched groups are empty.
        let groups: [String]
    }

    /// Case-insensitive regex match returning the whole match plus its capture
    /// groups.
    static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        func slice(_ index: Int) -> String {
            let groupRange = match.range(at: index)
            guard groupRange.location != NSNotFound,
                  let swiftRange = Swift.Range(groupRange, in: text)
            else { return "" }
            return String(text[swiftRange])
        }
        return Match(full: slice(0), groups: (1..<match.numberOfRanges).map(slice))
    }
}

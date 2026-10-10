import Foundation

// MARK: - Errors

enum BridgeError: Error, CustomStringConvertible {
    case invalid(String, String?)
    case denied(String, String?)
    case notFound(String, String?)
    case unsupported(String, String?)
    case ambiguous(String, String?)
    case failed(String, String?)

    var code: String {
        switch self {
        case .invalid: return "invalid_argument"
        case .denied: return "permission_denied"
        case .notFound: return "not_found"
        case .unsupported: return "unsupported"
        case .ambiguous: return "ambiguous_target"
        case .failed: return "operation_failed"
        }
    }

    var message: String {
        switch self {
        case .invalid(let m, _), .denied(let m, _), .notFound(let m, _),
             .unsupported(let m, _), .ambiguous(let m, _), .failed(let m, _):
            return m
        }
    }

    var hint: String? {
        switch self {
        case .invalid(_, let h), .denied(_, let h), .notFound(_, let h),
             .unsupported(_, let h), .ambiguous(_, let h), .failed(_, let h):
            return h
        }
    }

    var description: String { message }

    var json: [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let hint { error["hint"] = hint }
        return ["ok": false, "error": error]
    }
}

// MARK: - Environment

enum Env {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var writeMode: String {
        (environment["MAC_CALENDAR_WRITE_MODE"] ?? "ask").lowercased()
    }

    static var maxBodyChars: Int {
        Int(environment["MAC_CALENDAR_MAX_BODY_CHARS"] ?? "") ?? 8000
    }

    static var defaultLimit: Int {
        Int(environment["MAC_CALENDAR_DEFAULT_LIMIT"] ?? "") ?? 50
    }

    static var maxLimit: Int {
        Int(environment["MAC_CALENDAR_MAX_LIMIT"] ?? "") ?? 500
    }

    static var bridgeVersion: String { "0.1.3" }
}

// MARK: - Argument access

struct Args {
    let raw: [String: Any]

    init(_ raw: [String: Any]?) { self.raw = raw ?? [:] }

    subscript(key: String) -> Any? {
        guard let value = raw[key] else { return nil }
        if value is NSNull { return nil }
        return value
    }

    func has(_ key: String) -> Bool { self[key] != nil }

    func string(_ key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.invalid("Missing required string parameter '\(key)'.", nil)
        }
        return value
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? NSNumber { return value.boolValue }
        if let value = self[key] as? String {
            switch value.lowercased() {
            case "true", "yes", "y", "1": return true
            case "false", "no", "n", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func boolOr(_ key: String, _ fallback: Bool) -> Bool { bool(key) ?? fallback }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? NSNumber { return value.intValue }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }

    func intOr(_ key: String, _ fallback: Int) -> Int { int(key) ?? fallback }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func array(_ key: String) -> [Any] {
        if let value = self[key] as? [Any] { return value }
        if let value = self[key] { return [value] }
        return []
    }

    func strings(_ key: String) -> [String] {
        array(key).compactMap { item -> String? in
            if let s = item as? String { return s }
            if let n = item as? NSNumber { return n.stringValue }
            return nil
        }
    }

    func object(_ key: String) -> Args? {
        if let value = self[key] as? [String: Any] { return Args(value) }
        return nil
    }

    func objects(_ key: String) -> [Args] {
        array(key).compactMap { item in
            (item as? [String: Any]).map(Args.init)
        }
    }

    func keys() -> [String] { Array(raw.keys).sorted() }

    /// Merge additional keys without overwriting existing ones.
    func merging(_ extra: [String: Any]) -> Args {
        var merged = raw
        for (key, value) in extra where merged[key] == nil { merged[key] = value }
        return Args(merged)
    }
}

// MARK: - Result envelope

func ok(_ tool: String, _ fields: [String: Any]) -> [String: Any] {
    var result = fields
    result["ok"] = true
    result["tool"] = tool
    return result
}

func merge(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
    var merged = base
    for (key, value) in extra { merged[key] = value }
    return merged
}

// MARK: - Write guard

enum WriteDecision {
    case proceed
    case halt([String: Any])
}

/// Central safety gate for every mutating tool.
///
/// - `dry_run: true` never writes, whatever the mode is.
/// - In `ask` mode (the default) the caller must pass `confirm: true`.
/// - `MAC_CALENDAR_WRITE_MODE=direct` disables the confirmation requirement.
func writeGuard(
    _ args: Args,
    action: String,
    target: [String: Any],
    extra: [String: Any] = [:]
) -> WriteDecision {
    let mode = Env.writeMode
    var preview: [String: Any] = [
        "applied": false,
        "action": action,
        "target": target,
        "writeMode": mode,
    ]
    for (key, value) in extra { preview[key] = value }

    if args.bool("dry_run") == true {
        preview["dryRun"] = true
        preview["allowed"] = true
        preview["hint"] = "dry_run was requested, so nothing was written. Re-issue without dry_run to apply."
        return .halt(preview)
    }

    if mode != "direct" && args.bool("confirm") != true {
        preview["allowed"] = false
        preview["needsConfirm"] = true
        preview["hint"] = "Mutating operation not applied. Re-issue the exact same call with \"confirm\": true to apply it. Use dry_run: true for a preview that never writes."
        return .halt(preview)
    }

    return .proceed
}

// MARK: - Text helpers

func truncateBody(_ value: String?, label: String = "text") -> (String?, Bool) {
    guard let value else { return (nil, false) }
    let limit = Env.maxBodyChars
    if value.count <= limit { return (value, false) }
    let index = value.index(value.startIndex, offsetBy: limit)
    return (String(value[value.startIndex..<index]) + "\n…[truncated \(label); \(value.count) chars total]", true)
}

func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Blocking bridge for async EventKit calls

private final class ResultBox<T> {
    var value: T?
}

/// EventKit delivers reminder fetches asynchronously. Spin the main run loop
/// until the completion handler fires so the CLI and the MCP server can stay
/// synchronous.
func waitFor<T>(timeout: TimeInterval = 30, _ body: (@escaping (T) -> Void) -> Void) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    body { value in
        box.value = value
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
        if Date() > deadline {
            throw BridgeError.failed("Timed out waiting for EventKit after \(Int(timeout))s.", nil)
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    guard let value = box.value else {
        throw BridgeError.failed("EventKit returned no result.", nil)
    }
    return value
}

// MARK: - JSON

func jsonObject(_ value: Any, pretty: Bool) -> Data {
    var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted); options.insert(.sortedKeys) }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: options) {
        return data
    }
    // Fall back to a lossy representation instead of crashing on an
    // unserializable value.
    let fallback: [String: Any] = [
        "ok": false,
        "error": [
            "code": "serialization_failed",
            "message": "Result could not be encoded as JSON.",
        ],
    ]
    return (try? JSONSerialization.data(withJSONObject: fallback, options: options)) ?? Data("{}".utf8)
}

func jsonString(_ value: Any, pretty: Bool = false) -> String {
    String(data: jsonObject(value, pretty: pretty), encoding: .utf8) ?? "{}"
}

func parseJSONObject(_ text: String) throws -> [String: Any] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    guard let data = trimmed.data(using: .utf8) else {
        throw BridgeError.invalid("Arguments are not valid UTF-8.", nil)
    }
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        throw BridgeError.invalid("Arguments are not valid JSON: \(error.localizedDescription)", nil)
    }
    guard let object = parsed as? [String: Any] else {
        throw BridgeError.invalid("Arguments must be a JSON object.", nil)
    }
    return object
}

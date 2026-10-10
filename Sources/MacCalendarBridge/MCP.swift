import EventKit
import Foundation

/// Minimal, dependency-free MCP server over stdio.
///
/// Implements the subset of the Model Context Protocol that Codex and other
/// clients use for tool servers: `initialize`, `tools/list`, `tools/call`, plus
/// the usual no-op notifications. Messages are newline-delimited JSON-RPC 2.0.
enum MCP {

    static let protocolVersion = "2025-06-18"

    static let supportedProtocolVersions = [
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    static let instructions = """
    Tools for the real macOS Calendar and Reminders databases, via EventKit.

    Start with calendars_status to confirm access, then calendar_list_calendars / \
    reminders_list_lists to obtain exact container ids before writing anything.

    Conventions:
    - Dates are ISO-8601; naive values are read in the machine's time zone. \
    Output includes both 'iso' and a human-readable 'local' form, plus a weekday.
    - Mutating tools require "confirm": true unless MAC_CALENDAR_WRITE_MODE=direct. \
    Without it they return a preview and write nothing. "dry_run": true never writes.
    - Read-only or subscribed containers are refused with an explicit error.
    - Container names are matched exactly, then case-insensitively, then as a \
    substring; an ambiguous name is an error, never a guess.
    - Deleting a non-empty calendar or list additionally needs \
    "confirm_delete_contents": true. Prefer moving items instead.

    Prefer calendar_agenda for a whole day or week, calendar_find_free_slots \
    before proposing a meeting time, and calendar_quick_add for a phrase the user \
    typed. EventKit cannot add invitees: use \
    calendar_create_event_in_calendar_app for that.
    """

    static func serve(timeZone: TimeZone = .current) -> Int32 {
        let store = Store(timeZone: timeZone)
        var buffer = Data()
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput

        func emit(_ object: [String: Any]) {
            var data = jsonObject(object, pretty: false)
            data.append(0x0A)
            output.write(data)
        }

        while true {
            let chunk: Data?
            do {
                chunk = try input.read(upToCount: 65_536)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard !lineData.isEmpty else { continue }
                guard
                    let message = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
                else {
                    emit([
                        "jsonrpc": "2.0",
                        "id": NSNull(),
                        "error": ["code": -32700, "message": "Parse error"],
                    ])
                    continue
                }
                if let response = handle(message, store: store) {
                    emit(response)
                }
                if message["method"] as? String == "exit" { return 0 }
            }
        }
        return 0
    }

    static func handle(_ message: [String: Any], store: Store) -> [String: Any]? {
        guard let method = message["method"] as? String else {
            // A response to something we sent; nothing to do.
            return nil
        }
        let id = message["id"]
        let isNotification = id == nil || id is NSNull
        let params = (message["params"] as? [String: Any]) ?? [:]

        func success(_ result: [String: Any]) -> [String: Any]? {
            guard !isNotification else { return nil }
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        }

        func failure(_ code: Int, _ text: String) -> [String: Any]? {
            guard !isNotification else { return nil }
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let negotiated = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? supportedProtocolVersions[0]
            return success([
                "protocolVersion": negotiated,
                "capabilities": [
                    "tools": ["listChanged": false],
                ],
                "serverInfo": [
                    "name": "mac-calendar",
                    "title": "macOS Calendar & Reminders",
                    "version": Env.bridgeVersion,
                ],
                "instructions": instructions,
            ])

        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            return nil

        case "ping":
            return success([:])

        case "tools/list":
            return success(["tools": toolCatalogJSON()])

        case "tools/call":
            guard let name = params["name"] as? String else {
                return failure(-32602, "Missing 'name' in tools/call params.")
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            let result = runTool(name, arguments: arguments, store: store)
            let succeeded = (result["ok"] as? Bool) ?? false
            return success([
                "content": [
                    ["type": "text", "text": jsonString(result, pretty: true)],
                ],
                "isError": !succeeded,
                "structuredContent": result,
            ])

        case "resources/list":
            return success(["resources": []])

        case "prompts/list":
            return success(["prompts": []])

        case "logging/setLevel":
            return success([:])

        case "shutdown":
            return success([:])

        case "exit":
            return nil

        default:
            return failure(-32601, "Method '\(method)' is not supported by this server.")
        }
    }
}

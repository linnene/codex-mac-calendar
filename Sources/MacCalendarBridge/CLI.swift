import EventKit
import Foundation

/// Human-facing command line. The same tool registry backs both this CLI and the
/// MCP server, so anything an agent can do can be reproduced by hand.
enum CLI {

    static let usage = """
    mac-calendar-bridge — macOS Calendar & Reminders access for Codex

    USAGE
      mac-calendar-bridge <command> [options]

    COMMANDS
      mcp                     Run the MCP server over stdio (what Codex uses)
      tools                   List every tool with its JSON schema
      call <tool> [json]      Call one tool; JSON may be a literal, '-' for stdin,
                              or omitted when --arg pairs are used
      status                  Permission, account, and default-container report
      parse-date <text>       Show how a date expression is interpreted
      doctor                  Environment checks plus a status report
      permissions             Trigger the macOS consent prompts
      version                 Print version information
      help                    Print this message

    OPTIONS
      --arg key=value         Set a top-level tool argument (repeatable)
      --pretty                Pretty-print JSON output
      --markdown              With 'tools', emit the Markdown reference instead
      --timezone <IANA>       Time zone for this invocation

    EXAMPLES
      mac-calendar-bridge status
      mac-calendar-bridge call calendars_status --pretty
      mac-calendar-bridge call calendar_list_events --arg range=today --arg calendar='工作'
      mac-calendar-bridge call calendar_quick_add --arg text='明天下午3点和张伟开会1小时' --arg confirm=true
      echo '{"range":"this_week"}' | mac-calendar-bridge call calendar_agenda - --pretty
    """

    static func run(_ arguments: [String]) -> Int32 {
        var args = arguments
        var pretty = false
        var markdown = false
        var timeZone = TimeZone.current
        var pairs: [String: Any] = [:]

        // Peel off global options first so they may appear anywhere.
        var positional: [String] = []
        var index = 0
        while index < args.count {
            let value = args[index]
            switch value {
            case "--pretty", "-p":
                pretty = true
            case "--markdown", "--md":
                markdown = true
            case "--arg", "-a":
                index += 1
                if index < args.count, let (key, raw) = splitArgument(args[index]) {
                    pairs[key] = coerce(raw)
                } else {
                    FileHandle.standardError.write(Data("--arg needs key=value\n".utf8))
                    return 2
                }
            case "--timezone", "-z":
                index += 1
                if index < args.count, let zone = TimeZone(identifier: args[index]) {
                    timeZone = zone
                } else if index < args.count {
                    FileHandle.standardError.write(Data("Unknown time zone '\(args[index])'\n".utf8))
                    return 2
                }
            default:
                positional.append(value)
            }
            index += 1
        }
        args = positional

        guard let command = args.first else {
            print(usage)
            return 0
        }

        switch command {
        case "help", "--help", "-h":
            print(usage)
            return 0

        case "version", "--version":
            print("mac-calendar-bridge \(Env.bridgeVersion)")
            print("write mode: \(Env.writeMode)")
            print("support directory: \(Preferences.directory.path)")
            return 0

        case "mcp":
            return MCP.serve(timeZone: timeZone)

        case "tools":
            if markdown {
                print(toolCatalogMarkdown())
                return 0
            }
            let tools = toolCatalog()
            if pretty {
                print(jsonString(tools.map { tool -> [String: Any] in
                    [
                        "name": tool.name,
                        "title": tool.title,
                        "readOnly": tool.readOnly,
                        "description": tool.description,
                        "inputSchema": tool.schema,
                    ]
                }, pretty: true))
            } else {
                for tool in tools {
                    let marker = tool.readOnly ? " " : "W"
                    print("\(marker) \(tool.name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(tool.title)")
                }
                print("")
                print("\(tools.count) tools. 'W' marks tools that can modify data.")
            }
            return 0

        case "status":
            let store = Store(timeZone: timeZone)
            print(jsonString(ok("calendars_status", store.statusJSON()), pretty: true))
            return 0

        case "permissions":
            let store = Store(timeZone: timeZone)
            let result = try? store.requestAccess(events: true, reminders: true)
            print(jsonString(ok("calendars_request_access", result ?? store.permissionReport()), pretty: true))
            return result == nil ? 1 : 0

        case "parse-date":
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("parse-date needs a date expression.\n".utf8))
                return 2
            }
            let expression = args[1...].joined(separator: " ")
            do {
                let parsed = try Dates.parse(expression, timeZone: timeZone, futureBias: true)
                print(jsonString([
                    "input": expression,
                    "iso": Dates.iso(parsed.date, timeZone: timeZone),
                    "local": Dates.local(parsed.date, timeZone: timeZone),
                    "dateOnly": parsed.isDateOnly,
                    "matchedText": parsed.matchedText as Any? ?? NSNull(),
                    "timeZone": timeZone.identifier,
                ], pretty: true))
                return 0
            } catch let error as BridgeError {
                print(jsonString(error.json, pretty: true))
                return 1
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                return 1
            }

        case "doctor":
            return doctor(timeZone: timeZone, pretty: pretty)

        case "call":
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("call needs a tool name. Try 'tools'.\n".utf8))
                return 2
            }
            let name = args[1]
            var arguments = pairs
            var jsonSource: String?
            if args.count >= 3 {
                jsonSource = args[2]
            }
            if let jsonSource {
                do {
                    if jsonSource == "-" {
                        let data = FileHandle.standardInput.readDataToEndOfFile()
                        let text = String(data: data, encoding: .utf8) ?? ""
                        for (key, value) in try parseJSONObject(text) { arguments[key] = value }
                    } else if jsonSource.hasPrefix("{") {
                        for (key, value) in try parseJSONObject(jsonSource) { arguments[key] = value }
                    } else {
                        FileHandle.standardError.write(Data("Expected a JSON object or '-' for stdin.\n".utf8))
                        return 2
                    }
                } catch let error as BridgeError {
                    FileHandle.standardError.write(Data((error.message + "\n").utf8))
                    return 2
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    return 2
                }
            }

            let store = Store(timeZone: timeZone)
            let result = runTool(name, arguments: arguments, store: store)
            print(jsonString(result, pretty: pretty || true))
            let succeeded = (result["ok"] as? Bool) ?? false
            let applied = (result["applied"] as? Bool)
            if !succeeded { return 1 }
            return applied == false ? 3 : 0

        default:
            FileHandle.standardError.write(Data("Unknown command '\(command)'.\n\n\(usage)\n".utf8))
            return 2
        }
    }

    static func splitArgument(_ text: String) -> (String, String)? {
        guard let index = text.firstIndex(of: "=") else { return nil }
        let key = String(text[text.startIndex..<index])
        let value = String(text[text.index(after: index)...])
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    /// Turn `key=value` into the JSON type the tool schema expects.
    static func coerce(_ raw: String) -> Any {
        switch raw.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: break
        }
        if let number = Int(raw) { return number }
        if let number = Double(raw) { return number }
        if raw.hasPrefix("[") || raw.hasPrefix("{") {
            if let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return object
            }
        }
        return raw
    }

    static func doctor(timeZone: TimeZone, pretty: Bool) -> Int32 {
        let store = Store(timeZone: timeZone)
        var report: [String: Any] = [:]
        report["binary"] = CommandLine.arguments.first ?? "mac-calendar-bridge"
        report["version"] = Env.bridgeVersion
        report["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["writeMode"] = Env.writeMode
        report["writeModeIsValid"] = ["ask", "direct"].contains(Env.writeMode)
        report["toolCount"] = toolCatalog().count
        report["supportDirectoryWritable"] = FileManager.default.isWritableFile(atPath: Preferences.directory.deletingLastPathComponent().path)
        report["status"] = store.statusJSON()

        var problems: [String] = []
        if !["ask", "direct"].contains(Env.writeMode) {
            problems.append("MAC_CALENDAR_WRITE_MODE is '\(Env.writeMode)'; expected 'ask' or 'direct'. Falling back to 'ask' semantics.")
        }
        if !Store.canRead(store.eventAuthorization) {
            problems.append("Calendar Full Access is not granted; event reading and container colour editing will fail.")
        }
        if !Store.canRead(store.reminderAuthorization) {
            problems.append("Reminders Full Access is not granted; reminder tools will fail.")
        }
        if problems.isEmpty { problems.append("No problems detected.") }
        report["problems"] = problems

        print(jsonString(report, pretty: pretty || true))
        return problems.count == 1 && problems[0] == "No problems detected." ? 0 : 1
    }
}

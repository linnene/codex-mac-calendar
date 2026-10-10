import EventKit
import Foundation

// MARK: - Tool registry

struct Tool {
    let name: String
    let title: String
    let description: String
    let readOnly: Bool
    let schema: [String: Any]
    let handler: (Store, Args) throws -> [String: Any]
}

// MARK: Schema helpers

private func str(_ description: String) -> [String: Any] {
    ["type": "string", "description": description]
}

private func int(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> [String: Any] {
    var schema: [String: Any] = ["type": "integer", "description": description]
    if let minimum { schema["minimum"] = minimum }
    if let maximum { schema["maximum"] = maximum }
    return schema
}

private func num(_ description: String) -> [String: Any] {
    ["type": "number", "description": description]
}

private func boolean(_ description: String) -> [String: Any] {
    ["type": "boolean", "description": description]
}

private func enumeration(_ description: String, _ values: [String]) -> [String: Any] {
    ["type": "string", "description": description, "enum": values]
}

private func strings(_ description: String) -> [String: Any] {
    ["type": "array", "items": ["type": "string"], "description": description]
}

private func object(_ description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
    var schema: [String: Any] = ["type": "object", "description": description, "properties": properties]
    if !required.isEmpty { schema["required"] = required }
    return schema
}

private func array(_ description: String, items: [String: Any]) -> [String: Any] {
    ["type": "array", "items": items, "description": description]
}

private func schema(
    _ properties: [String: Any],
    required: [String] = [],
    extra: [String: Any] = [:]
) -> [String: Any] {
    var value: [String: Any] = ["type": "object", "properties": properties]
    if !required.isEmpty { value["required"] = required }
    value["additionalProperties"] = false
    for (key, item) in extra { value[key] = item }
    return value
}

// MARK: Reusable fragments

private let confirmProperty = boolean("Must be true to actually apply a change while write mode is 'ask' (the default). Without it, mutating tools return a preview and write nothing.")
private let dryRunProperty = boolean("Preview only. Never writes, in any write mode.")
private let timeZoneProperty = str("IANA time zone for interpreting and rendering dates, e.g. 'Asia/Shanghai'. Defaults to the machine's current zone.")
private let rangeProperty = enumeration(
    "Convenience range preset. Ignored when 'start' is given.",
    Dates.presetNames
)
private let startProperty = str("Range start. A date or date-time: '2026-10-10', '2026-10-10T09:00', '+3d', 'tomorrow'.")
private let endProperty = str("Range end (exclusive). Same formats as 'start'. Defaults to one day after 'start'.")
private let eventEndProperty = str("End date-time. Defaults to start + duration_minutes, or +1 hour. For an all-day event this names the LAST day the event covers, inclusive: a one-day all-day event needs no 'end', and 'end' equal to 'start' means one day, not zero.")
private let durationProperty = int("Length in minutes. Rounded up to whole days for an all-day event.", minimum: 1)
private let limitProperty = int("Maximum number of items to return. Defaults to 50, capped at \(Env.maxLimit).", minimum: 1, maximum: Env.maxLimit)
private let calendarNameProperty = str("Calendar name, or the special values 'all' or '*'. Names are matched exactly first, then case-insensitively, then as a substring; an ambiguous match is an error rather than a guess.")
private let calendarIdProperty = str("Exact calendar identifier from calendar_list_calendars. Takes precedence over the name.")
private let listNameProperty = str("Reminder list name, or 'all' / '*'. Ambiguous matches are an error.")
private let listIdProperty = str("Exact reminder-list identifier from reminders_list_lists. Takes precedence over the name.")
private let idProperty = str("Exact item identifier as returned by the list tools.")
private let occurrenceProperty = str("For a recurring event, the occurrenceDate value returned by calendar_list_events. Needed to target one occurrence instead of the whole series.")
private let spanProperty = enumeration(
    "Which part of a recurring series the change applies to.",
    ["this", "this_and_future", "all"]
)
private let alarmsProperty = array(
    "Reminder offsets for the item. Each entry is {\"minutes_before\": 15} (relative), {\"at\": \"2026-10-10T09:00\"} (absolute), or {\"location\": {\"title\": \"Office\", \"latitude\": 31.23, \"longitude\": 121.47, \"radius\": 150, \"on\": \"enter\"}} (geofence). Passing the array replaces all existing alarms; pass an empty array to remove them.",
    items: object(
        "One alarm.",
        properties: [
            "minutes_before": num("Fire this many minutes before the start."),
            "minutes_after": num("Fire this many minutes after the start."),
            "at": str("Absolute fire time."),
            "sound": str("Sound name, e.g. 'default'."),
            "location": object(
                "Geofence trigger.",
                properties: [
                    "title": str("Place name."),
                    "latitude": num("Latitude."),
                    "longitude": num("Longitude."),
                    "radius": num("Radius in metres."),
                    "on": enumeration("Trigger direction.", ["enter", "leave"]),
                ],
                required: ["title"]
            ),
        ]
    )
)
private let recurrenceProperty = array(
    "Recurrence rule. Passing this array replaces the existing rules; pass an empty array to make the item non-recurring.",
    items: object(
        "One recurrence rule.",
        properties: [
            "frequency": enumeration("How often it repeats.", ["daily", "weekly", "monthly", "yearly"]),
            "interval": int("Repeat every N units. Defaults to 1.", minimum: 1),
            "days_of_week": strings("Weekdays for weekly/monthly rules: su, mo, tu, we, th, fr, sa. Use 'tu#2' for the second Tuesday of the month."),
            "days_of_month": array("Days of the month, e.g. [1, 15]. Negative counts from the end.", items: ["type": "integer"]),
            "months_of_year": array("Months, 1-12.", items: ["type": "integer"]),
            "count": int("Stop after this many occurrences.", minimum: 1),
            "until": str("Stop on this date (inclusive)."),
        ],
        required: ["frequency"]
    )
)
private let clearProperty = strings("Field names to reset to empty: notes, location, url, alarms, recurrence, timezone (events) or notes, url, location, due, start, alarms, recurrence (reminders).")

// MARK: Tool catalog

func toolCatalog() -> [Tool] {
    var tools: [Tool] = []

    // ---------- Diagnostics ----------

    tools.append(Tool(
        name: "calendars_status",
        title: "Check calendar and reminders access",
        description: "Report whether this process can read/write macOS Calendars and Reminders, which accounts exist, what the current defaults are, and exactly how to fix a missing permission. Call this first whenever another tool returns permission_denied, or before a batch of calendar work.",
        readOnly: true,
        schema: schema([:]),
        handler: { store, _ in store.statusJSON() }
    ))

    tools.append(Tool(
        name: "calendars_request_access",
        title: "Trigger the macOS permission prompt",
        description: "Ask macOS for Full Access to Calendars and Reminders by triggering the native consent dialog. Use after calendars_status reports notDetermined or denied. If macOS has already recorded a denial, the dialog will not reappear and the user must change it in System Settings.",
        readOnly: true,
        schema: schema([
            "calendars": boolean("Request Calendars access. Defaults to true."),
            "reminders": boolean("Request Reminders access. Defaults to true."),
        ]),
        handler: { store, args in
            try store.requestAccess(
                events: args.boolOr("calendars", true),
                reminders: args.boolOr("reminders", true)
            )
        }
    ))

    tools.append(Tool(
        name: "calendars_open_privacy_settings",
        title: "Open the right System Settings pane",
        description: "Open System Settings directly on the Calendars or Reminders privacy pane so the user can grant Full Access. Use when a permission cannot be fixed by a prompt.",
        readOnly: true,
        schema: schema([
            "pane": enumeration("Which privacy pane to open.", ["calendars", "reminders"]),
        ], required: ["pane"]),
        handler: { _, args in
            let pane = try args.requiredString("pane").lowercased()
            let target: String
            switch pane {
            case "calendars": target = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            case "reminders": target = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
            default: throw BridgeError.invalid("Unknown pane '\(pane)'.", "Use 'calendars' or 'reminders'.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [target]
            try process.run()
            return ["opened": target, "note": "System Settings should now be in front. Grant Full Access, then re-run calendars_status."]
        }
    ))

    tools.append(Tool(
        name: "calendars_list_accounts",
        title: "List accounts",
        description: "List the accounts (iCloud, Google, Exchange, local, subscribed) that hold calendars and reminder lists, with the number of containers in each. Use it to know which account a new calendar or list can be created in.",
        readOnly: true,
        schema: schema([:]),
        handler: { store, args in try store.accountsJSON(args) }
    ))

    tools.append(Tool(
        name: "calendars_color_palette",
        title: "Get the colour palette",
        description: "Return the named colour palette used by Calendar.app with hex values, so a container colour can be chosen by name or hex. Call this when the user asks for 'an orange calendar' or an unspecified colour.",
        readOnly: true,
        schema: schema([
            "query": str("Optional filter, e.g. 'orange' or '橙'."),
        ]),
        handler: { _, args in Colors.paletteResult(query: args.string("query")) }
    ))

    // ---------- Calendars (event containers) ----------

    tools.append(Tool(
        name: "calendar_list_calendars",
        title: "List calendars",
        description: "List every calendar with its id, account, colour, and whether it can be written to. Always call this before creating or moving an event so the target calendar id is known and exact.",
        readOnly: true,
        schema: schema([
            "account": str("Only return calendars belonging to this account title."),
            "writable_only": boolean("Only return calendars that accept new events."),
        ]),
        handler: { store, args in try store.containerListJSON(args, entity: .event) }
    ))

    tools.append(Tool(
        name: "calendar_create_calendar",
        title: "Create a calendar",
        description: "Create a new calendar (an event group) in a given account, optionally with a colour. Use when the user asks for a new group to organise events under.",
        readOnly: false,
        schema: schema([
            "title": str("Name of the new calendar."),
            "color": str("Colour: a palette name ('orange') or a hex value ('#FF9500')."),
            "account": str("Account title to create it in, e.g. 'iCloud'. Defaults to iCloud, then any CalDAV account, then the first writable account."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["title"]),
        handler: { store, args in try store.containerCreateJSON(args, entity: .event) }
    ))

    tools.append(Tool(
        name: "calendar_update_calendar",
        title: "Rename or recolour a calendar",
        description: "Rename a calendar and/or change its colour. Identify the target with 'id' (preferred) or 'calendar'. Calendars cannot be moved between accounts; recreate and move the events instead.",
        readOnly: false,
        schema: schema([
            "id": calendarIdProperty,
            "calendar": str("Calendar name to match when 'id' is not given."),
            "new_title": str("New name."),
            "color": str("New colour: palette name or hex."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.containerUpdateJSON(args, entity: .event) }
    ))

    tools.append(Tool(
        name: "calendar_delete_calendar",
        title: "Delete a calendar",
        description: "Delete a calendar. Non-empty calendars are refused unless 'confirm_delete_contents': true is also passed, because the events inside are deleted too and the change syncs to every device. Prefer calendar_move_event when the user only wants the events elsewhere.",
        readOnly: false,
        schema: schema([
            "id": calendarIdProperty,
            "calendar": str("Calendar name to match when 'id' is not given."),
            "confirm_delete_contents": boolean("Acknowledge that the events inside the calendar will be deleted as well."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.containerDeleteJSON(args, entity: .event) }
    ))

    tools.append(Tool(
        name: "calendars_set_default",
        title: "Pin a default calendar or list",
        description: "Choose which calendar or reminder list this bridge uses when a tool is called without an explicit target. macOS provides no API to change the system default, so the choice is stored in the bridge's own preferences file.",
        readOnly: false,
        schema: schema([
            "kind": enumeration("Which default to change.", ["calendar", "reminder_list"]),
            "id": str("Container id from calendar_list_calendars or reminders_list_lists."),
            "calendar": str("Container name to match when 'id' is not given."),
            "clear": boolean("Remove the pinned default and fall back to the system default."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["kind"]),
        handler: { store, args in
            let kind = try args.requiredString("kind").lowercased()
            switch kind {
            case "calendar", "event", "calendars":
                return try store.containerSetDefaultJSON(args, entity: .event)
            case "reminder_list", "list", "reminders":
                return try store.containerSetDefaultJSON(args, entity: .reminder)
            default:
                throw BridgeError.invalid("Unknown kind '\(kind)'.", "Use 'calendar' or 'reminder_list'.")
            }
        }
    ))

    // ---------- Reminder lists ----------

    tools.append(Tool(
        name: "reminders_list_lists",
        title: "List reminder lists",
        description: "List every reminder list with its id, account, colour, and writability. Call this before creating or moving a reminder so the target list id is exact.",
        readOnly: true,
        schema: schema([
            "account": str("Only return lists belonging to this account title."),
            "writable_only": boolean("Only return lists that accept new reminders."),
        ]),
        handler: { store, args in try store.containerListJSON(args, entity: .reminder) }
    ))

    tools.append(Tool(
        name: "reminders_create_list",
        title: "Create a reminder list",
        description: "Create a new reminder list (a group of reminders), optionally with a colour.",
        readOnly: false,
        schema: schema([
            "title": str("Name of the new list."),
            "color": str("Colour: a palette name ('teal') or a hex value ('#30B0C7')."),
            "account": str("Account title to create it in, e.g. 'iCloud'."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["title"]),
        handler: { store, args in try store.containerCreateJSON(args, entity: .reminder) }
    ))

    tools.append(Tool(
        name: "reminders_update_list",
        title: "Rename or recolour a reminder list",
        description: "Rename a reminder list and/or change its colour.",
        readOnly: false,
        schema: schema([
            "id": listIdProperty,
            "list": str("List name to match when 'id' is not given."),
            "new_title": str("New name."),
            "color": str("New colour: palette name or hex."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.containerUpdateJSON(args, entity: .reminder) }
    ))

    tools.append(Tool(
        name: "reminders_delete_list",
        title: "Delete a reminder list",
        description: "Delete a reminder list. Non-empty lists are refused unless 'confirm_delete_contents': true is passed, since every reminder inside is deleted and the change syncs everywhere. Use reminders_move first if the reminders should survive.",
        readOnly: false,
        schema: schema([
            "id": listIdProperty,
            "list": str("List name to match when 'id' is not given."),
            "confirm_delete_contents": boolean("Acknowledge that the reminders inside will be deleted too."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.containerDeleteJSON(args, entity: .reminder) }
    ))

    // ---------- Events ----------

    tools.append(Tool(
        name: "calendar_list_events",
        title: "List events in a range",
        description: "List events in a time range, optionally filtered by calendar or keyword. Use this to answer 'what is on my calendar'. For a merged view that also includes due reminders, use calendar_agenda instead.",
        readOnly: true,
        schema: schema([
            "range": rangeProperty,
            "start": startProperty,
            "end": endProperty,
            "calendar": calendarNameProperty,
            "calendars": strings("Several calendars at once."),
            "calendar_ids": strings("Several calendar ids at once."),
            "query": str("Case-insensitive keyword matched against title, location, notes, URL, calendar name, and attendee names."),
            "exclude_all_day": boolean("Skip all-day events."),
            "include_details": boolean("Include notes, attendees, alarms, and recurrence for each event. Off by default to keep output small."),
            "limit": limitProperty,
            "timezone": timeZoneProperty,
        ]),
        handler: { store, args in try store.eventListJSON(args, defaultRange: "today") }
    ))

    tools.append(Tool(
        name: "calendar_search_events",
        title: "Search events",
        description: "Search events by keyword over a wide window (default: the last 30 days plus the next 90). Use for 'when did I last meet X' or 'find the event about Y', where the date is unknown.",
        readOnly: true,
        schema: schema([
            "query": str("Keyword to search for."),
            "start": startProperty,
            "end": endProperty,
            "range": rangeProperty,
            "calendar": calendarNameProperty,
            "calendars": strings("Several calendars at once."),
            "limit": limitProperty,
            "include_details": boolean("Include notes, attendees, alarms, and recurrence."),
            "timezone": timeZoneProperty,
        ], required: ["query"]),
        handler: { store, args in
            var merged = args
            if !args.has("start") && !args.has("range") {
                let now = Date()
                merged = args.merging([
                    "start": Dates.iso(now.addingTimeInterval(-86_400 * 30), timeZone: .current),
                    "end": Dates.iso(now.addingTimeInterval(86_400 * 90), timeZone: .current),
                ])
            }
            var result = try store.eventListJSON(merged, defaultRange: "next_30_days")
            result["searchNote"] = "Searched start/end of \(result["range"].map { "\($0)" } ?? "range") with query '\(args.string("query") ?? "")'. Re-run with explicit start/end to widen."
            return result
        }
    ))

    tools.append(Tool(
        name: "calendar_get_event",
        title: "Get one event",
        description: "Fetch a single event with full detail: notes, URL, location, alarms, recurrence, attendees, availability, time zone, and creation/modification dates.",
        readOnly: true,
        schema: schema([
            "id": idProperty,
            "occurrence_date": occurrenceProperty,
            "timezone": timeZoneProperty,
        ], required: ["id"]),
        handler: { store, args in try store.eventGetJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_create_event",
        title: "Create an event",
        description: "Create a calendar event. Give 'start' plus either 'end' or 'duration_minutes'; when neither end nor duration is given the default is one hour. The target calendar must be writable.",
        readOnly: false,
        schema: schema([
            "title": str("Event title."),
            "start": str("Start date-time, e.g. '2026-10-10T15:00', 'tomorrow 15:00', '+2h'."),
            "end": eventEndProperty,
            "duration_minutes": durationProperty,
            "all_day": boolean("Create an all-day event. 'start' is snapped to midnight and the event covers whole days; use 'end' to span several days."),
            "calendar": calendarNameProperty,
            "calendar_id": calendarIdProperty,
            "timezone": timeZoneProperty,
            "location": str("Free-text location."),
            "notes": str("Free-text notes."),
            "url": str("URL to attach."),
            "availability": enumeration("Free/busy status.", ["busy", "free", "tentative", "unavailable"]),
            "alarms": alarmsProperty,
            "recurrence": recurrenceProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["title", "start"]),
        handler: { store, args in try store.eventCreateJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_update_event",
        title: "Update an event",
        description: "Change fields on an existing event. Only the fields you pass are modified. For a recurring series, pass 'occurrence_date' to pick the occurrence and 'span' to choose how much of the series changes.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "occurrence_date": occurrenceProperty,
            "span": spanProperty,
            "title": str("New title."),
            "start": str("New start."),
            "end": eventEndProperty,
            "duration_minutes": int("New length; recomputes the end from the start. Rounded up to whole days for an all-day event.", minimum: 1),
            "all_day": boolean("Switch between all-day and timed. An all-day event keeps its day span unless 'end' or 'duration_minutes' is also given."),
            "timezone": timeZoneProperty,
            "location": str("New location. Pass an empty string to clear it."),
            "notes": str("New notes. Pass an empty string to clear them."),
            "url": str("New URL. Pass an empty string to clear it."),
            "availability": enumeration("Free/busy status.", ["busy", "free", "tentative", "unavailable"]),
            "alarms": alarmsProperty,
            "recurrence": recurrenceProperty,
            "clear": clearProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["id"]),
        handler: { store, args in try store.eventUpdateJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_delete_event",
        title: "Delete an event",
        description: "Delete an event, or one occurrence / the whole remainder of a recurring series. Read-only calendars are refused.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "occurrence_date": occurrenceProperty,
            "span": spanProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["id"]),
        handler: { store, args in try store.eventDeleteJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_move_event",
        title: "Move an event to another calendar",
        description: "Move an event to a different calendar. Invitations cannot be moved; those return an explicit error.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "occurrence_date": occurrenceProperty,
            "calendar": calendarNameProperty,
            "calendar_id": calendarIdProperty,
            "span": spanProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["id"]),
        handler: { store, args in try store.eventMoveJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_duplicate_event",
        title: "Duplicate an event",
        description: "Copy an event, optionally shifted in time or into another calendar. Useful for 'do that again next week'.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "occurrence_date": occurrenceProperty,
            "start": str("Start of the copy. Defaults to the original start plus offset_minutes."),
            "offset_minutes": int("Shift the copy by this many minutes from the original."),
            "title": str("Title for the copy. Defaults to '<original> (copy)'."),
            "calendar": calendarNameProperty,
            "calendar_id": calendarIdProperty,
            "timezone": timeZoneProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["id"]),
        handler: { store, args in try store.eventDuplicateJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_quick_add",
        title: "Quick add from natural language",
        description: "Create an event from a phrase such as '明天下午3点和设计组评审1小时' or 'lunch with Ana next tuesday 12:30 for 90 minutes'. The date, duration, and title are parsed and echoed back under 'parsed' so the interpretation can be checked. Always show the parsed result to the user.",
        readOnly: false,
        schema: schema([
            "text": str("The phrase to parse."),
            "calendar": calendarNameProperty,
            "calendar_id": calendarIdProperty,
            "timezone": timeZoneProperty,
            "title": str("Override the parsed title."),
            "duration_minutes": int("Override the parsed duration. For an all-day event this is rounded up to whole days.", minimum: 1),
            "all_day": boolean("Force an all-day event."),
            "location": str("Location to attach."),
            "notes": str("Notes to attach."),
            "url": str("URL to attach."),
            "alarms": alarmsProperty,
            "recurrence": recurrenceProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["text"]),
        handler: { store, args in try store.quickAddJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_event_conflicts",
        title: "Find overlapping events",
        description: "Report pairs of overlapping events in a range, with the overlap window. Use to warn about double-booking before creating an event.",
        readOnly: true,
        schema: schema([
            "range": rangeProperty,
            "start": startProperty,
            "end": endProperty,
            "calendar": calendarNameProperty,
            "calendars": strings("Several calendars at once."),
            "include_all_day": boolean("Also treat all-day events as blockable."),
            "timezone": timeZoneProperty,
        ]),
        handler: { store, args in try store.conflictsJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_find_free_slots",
        title: "Find free time",
        description: "Compute open windows of at least a given length inside a working day, honouring existing events. Use for 'when am I free for an hour tomorrow' before proposing a meeting time.",
        readOnly: true,
        schema: schema([
            "range": rangeProperty,
            "start": startProperty,
            "end": endProperty,
            "duration_minutes": int("Minimum useful slot length. Defaults to 60.", minimum: 5),
            "workday_start": str("Local clock time the day starts, 'HH:mm'. Defaults to 09:00."),
            "workday_end": str("Local clock time the day ends, 'HH:mm'. Defaults to 18:00."),
            "min_lead_minutes": int("Ignore slots starting sooner than this many minutes from now.", minimum: 0),
            "calendar": calendarNameProperty,
            "calendars": strings("Only these calendars make time busy."),
            "include_free_events": boolean("Treat events marked 'free' as busy anyway."),
            "all_day_blocks": boolean("Let all-day events block the whole day. Defaults to true."),
            "include_empty_days": boolean("Also return days with no free slots, for a complete picture."),
            "timezone": timeZoneProperty,
        ]),
        handler: { store, args in try store.freeSlotsJSON(args) }
    ))

    tools.append(Tool(
        name: "calendar_create_event_in_calendar_app",
        title: "Hand an event to Calendar.app",
        description: "Build a prefilled event and open it in Calendar.app so the user can add invitees, attachments, or a conference link before saving. This is the only path for inviting people, because EventKit exposes attendees as read-only. Nothing is saved until the user confirms in Calendar.app.",
        readOnly: false,
        schema: schema([
            "title": str("Event title."),
            "start": str("Start date-time."),
            "end": eventEndProperty,
            "duration_minutes": int("Length in minutes when 'end' is absent. Rounded up to whole days for an all-day event.", minimum: 1),
            "all_day": boolean("All-day event."),
            "timezone": timeZoneProperty,
            "location": str("Location."),
            "notes": str("Notes."),
            "url": str("URL."),
            "attendees": strings("Email addresses to invite."),
            "alarm_minutes_before": array("One or more alarm offsets in minutes before the start, e.g. [15, 1440].", items: ["type": "integer"]),
            "availability": enumeration("Free/busy status.", ["busy", "free", "tentative", "unavailable"]),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["title", "start"]),
        handler: { store, args in try store.calendarAppHandoffJSON(args) }
    ))

    // ---------- Reminders ----------

    tools.append(Tool(
        name: "reminders_list",
        title: "List reminders",
        description: "List reminders filtered by list, completion state, due range, priority, or keyword. Defaults to open reminders sorted by due date, undated last.",
        readOnly: true,
        schema: schema([
            "list": listNameProperty,
            "lists": strings("Several lists at once."),
            "list_ids": strings("Several list ids at once."),
            "status": enumeration("Completion filter. Defaults to incomplete.", ["incomplete", "completed", "all"]),
            "query": str("Case-insensitive keyword matched against title, notes, and list name."),
            "due_on": str("Only reminders due on this calendar day."),
            "due_after": str("Only reminders due at or after this moment."),
            "due_before": str("Only reminders due at or before this moment."),
            "overdue_only": boolean("Only overdue, still-open reminders."),
            "has_due": boolean("true for reminders with a due date, false for those without."),
            "priority": enumeration("Filter by priority bucket.", ["none", "low", "medium", "high"]),
            "sort": enumeration("Sort order. Defaults to due.", ["due", "created", "completion", "priority", "title", "list"]),
            "include_details": boolean("Include notes, URL, alarms, and recurrence."),
            "limit": limitProperty,
            "timezone": timeZoneProperty,
        ]),
        handler: { store, args in try store.reminderListJSON(args) }
    ))

    tools.append(Tool(
        name: "reminders_get",
        title: "Get one reminder",
        description: "Fetch a single reminder with full detail: notes, URL, due date, alarms, recurrence, priority, and completion state.",
        readOnly: true,
        schema: schema([
            "id": idProperty,
            "timezone": timeZoneProperty,
        ], required: ["id"]),
        handler: { store, args in try store.reminderGetJSON(args) }
    ))

    tools.append(Tool(
        name: "reminders_create",
        title: "Create a reminder",
        description: "Create a reminder in a list, with an optional due date, alert offsets, priority, URL, and recurrence. Use for anything the user wants to be reminded about rather than a timed meeting.",
        readOnly: false,
        schema: schema([
            "title": str("Reminder title."),
            "list": listNameProperty,
            "list_id": listIdProperty,
            "due": str("Due date or date-time. A date-only value ('2026-10-10') creates an all-day due date."),
            "due_date_only": boolean("Force the due date to ignore the time of day."),
            "remind_at_minutes": int("Convenience: a single alert this many minutes before the due date."),
            "priority": enumeration("Priority bucket, or an integer 0-9.", ["none", "low", "medium", "high", "0", "1", "5", "9"]),
            "notes": str("Notes body."),
            "url": str("URL to attach."),
            "location": str("Free-text location."),
            "alarms": alarmsProperty,
            "recurrence": recurrenceProperty,
            "timezone": timeZoneProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["title"]),
        handler: { store, args in try store.reminderCreateJSON(args) }
    ))

    tools.append(Tool(
        name: "reminders_update",
        title: "Update a reminder",
        description: "Change fields on one reminder, including moving it to another list. Only the fields you pass are modified.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "title": str("New title."),
            "list": listNameProperty,
            "list_id": listIdProperty,
            "due": str("New due date or date-time. Pass an empty string to clear it."),
            "due_date_only": boolean("Force the due date to ignore the time of day."),
            "start_date": str("New start date. Pass an empty string to clear it."),
            "priority": enumeration("Priority bucket, or an integer 0-9.", ["none", "low", "medium", "high", "0", "1", "5", "9"]),
            "notes": str("New notes."),
            "url": str("New URL."),
            "location": str("New location."),
            "alarms": alarmsProperty,
            "recurrence": recurrenceProperty,
            "clear": clearProperty,
            "timezone": timeZoneProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ], required: ["id"]),
        handler: { store, args in try store.reminderUpdateJSON(args) }
    ))

    tools.append(Tool(
        name: "reminders_complete",
        title: "Complete reminders",
        description: "Mark one or more reminders as completed. Accepts a single id or a batch.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "ids": strings("Several reminder ids."),
            "completed_at": str("Completion timestamp to record. Defaults to now."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.reminderCompleteJSON(args, complete: true) }
    ))

    tools.append(Tool(
        name: "reminders_uncomplete",
        title: "Reopen reminders",
        description: "Mark one or more reminders as not completed again.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "ids": strings("Several reminder ids."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.reminderCompleteJSON(args, complete: false) }
    ))

    tools.append(Tool(
        name: "reminders_delete",
        title: "Delete reminders",
        description: "Permanently delete one or more reminders. This cannot be undone and syncs to every device on the account.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "ids": strings("Several reminder ids."),
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.reminderDeleteJSON(args) }
    ))

    tools.append(Tool(
        name: "reminders_move",
        title: "Move reminders to another list",
        description: "Move one or more reminders to a different list. This is the safe alternative to deleting a list.",
        readOnly: false,
        schema: schema([
            "id": idProperty,
            "ids": strings("Several reminder ids."),
            "list": listNameProperty,
            "list_id": listIdProperty,
            "confirm": confirmProperty,
            "dry_run": dryRunProperty,
        ]),
        handler: { store, args in try store.reminderMoveJSON(args) }
    ))

    // ---------- Combined ----------

    tools.append(Tool(
        name: "calendar_agenda",
        title: "Today / this week at a glance",
        description: "Merge calendar events and due reminders into one time-ordered timeline for a range, including overdue reminders. This is the fastest way to answer 'what does my day look like', 'what is on this week', or 'am I free this afternoon'.",
        readOnly: true,
        schema: schema([
            "range": rangeProperty,
            "start": startProperty,
            "end": endProperty,
            "lists": strings("Restrict reminders to these lists."),
            "calendars": strings("Restrict events to these calendars."),
            "include_events": boolean("Include events. Defaults to true."),
            "include_reminders": boolean("Include reminders. Defaults to true."),
            "include_completed": boolean("Also include reminders completed inside the range."),
            "include_overdue": boolean("Surface open reminders that are already overdue. Defaults to true."),
            "limit": int("Maximum timeline entries. Defaults to 100.", minimum: 1, maximum: Env.maxLimit),
            "timezone": timeZoneProperty,
        ]),
        handler: { store, args in try store.agendaJSON(args) }
    ))

    return tools
}

func toolCatalogJSON() -> [[String: Any]] {
    toolCatalog().map { tool in
        [
            "name": tool.name,
            "title": tool.title,
            "description": tool.description,
            "inputSchema": tool.schema,
            "annotations": [
                "title": tool.title,
                "readOnlyHint": tool.readOnly,
                "destructiveHint": !tool.readOnly && tool.name.contains("delete"),
                "idempotentHint": tool.readOnly,
                "openWorldHint": false,
            ],
        ]
    }
}

/// Markdown rendering of the catalogue, used to generate docs/tools.md so the
/// documentation cannot drift from the schemas.
func toolCatalogMarkdown() -> String {
    var lines: [String] = [
        "# Tool reference",
        "",
        "Generated by `scripts/make-docs.sh` from the tool schemas. Do not edit by hand.",
        "",
        "`read` tools never modify anything. Every other tool honours the confirmation",
        "contract described in the README: it writes nothing unless the request carries",
        "`\"confirm\": true`, and `\"dry_run\": true` never writes.",
        "",
        "| Tool | Access | Purpose |",
        "| --- | --- | --- |",
    ]
    for tool in toolCatalog() {
        lines.append("| [`\(tool.name)`](#\(tool.name.lowercased())) | \(tool.readOnly ? "read" : "write") | \(tool.title) |")
    }

    for tool in toolCatalog() {
        lines.append("")
        lines.append("## `\(tool.name)`")
        lines.append("")
        lines.append(tool.description)
        lines.append("")

        let properties = (tool.schema["properties"] as? [String: Any]) ?? [:]
        let required = Set((tool.schema["required"] as? [String]) ?? [])
        if properties.isEmpty {
            lines.append("Takes no arguments.")
            continue
        }
        lines.append("| Argument | Type | Required | Description |")
        lines.append("| --- | --- | --- | --- |")
        for key in properties.keys.sorted() {
            let entry = (properties[key] as? [String: Any]) ?? [:]
            var type = (entry["type"] as? String) ?? "any"
            if type == "array", let items = entry["items"] as? [String: Any] {
                type = "array of \((items["type"] as? String) ?? "any")"
            }
            var description = (entry["description"] as? String) ?? ""
            if let values = entry["enum"] as? [String] {
                description += " One of: \(values.map { "`\($0)`" }.joined(separator: ", "))."
            }
            description = description.replacingOccurrences(of: "|", with: "\\|")
            let marker = required.contains(key) ? "yes" : "no"
            lines.append("| `\(key)` | \(type) | \(marker) | \(description) |")
        }
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

func toolNamed(_ name: String) -> Tool? {
    toolCatalog().first { $0.name == name || $0.title == name }
}

/// Run a tool and wrap the result in the standard envelope.
func runTool(_ name: String, arguments: [String: Any], store: Store) -> [String: Any] {
    guard let tool = toolNamed(name) else {
        let available = toolCatalog().map(\.name).joined(separator: ", ")
        return [
            "ok": false,
            "error": [
                "code": "unknown_tool",
                "message": "No tool named '\(name)'.",
                "hint": "Available tools: \(available).",
            ],
        ]
    }
    do {
        let args = Args(arguments)
        let result = try tool.handler(store, args)
        return ok(tool.name, result)
    } catch let error as BridgeError {
        var payload = error.json
        payload["tool"] = tool.name
        return payload
    } catch {
        return [
            "ok": false,
            "tool": tool.name,
            "error": [
                "code": "operation_failed",
                "message": "\(error)",
            ],
        ]
    }
}

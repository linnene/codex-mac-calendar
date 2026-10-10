# Reference

Everything below the chat surface: MCP wiring, configuration, error codes, and
how the pieces fit together. For the tool-by-tool argument tables see
[tools.md](tools.md), which is generated from the schemas.

## Manual MCP client setup

Codex reads this from [`plugins/mac-calendar/.mcp.json`](../plugins/mac-calendar/.mcp.json).
Any other MCP client can point at the same binary:

```json
{
  "mcpServers": {
    "mac_calendar": {
      "command": "/absolute/path/to/plugins/mac-calendar/bin/mac-calendar-bridge",
      "args": ["mcp"],
      "env": { "MAC_CALENDAR_WRITE_MODE": "ask" }
    }
  }
}
```

The server speaks newline-delimited JSON-RPC 2.0 over stdio and implements
`initialize`, `tools/list`, `tools/call`, `ping`, and the standard empty
`resources/list` / `prompts/list`. Protocol versions `2025-06-18`, `2025-03-26`,
and `2024-11-05` are accepted; the client's version is echoed back.

`tools/call` returns both a `content` text block (pretty-printed JSON) and
`structuredContent` holding the same object, so clients that surface structured
data do not have to re-parse the text.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `MAC_CALENDAR_WRITE_MODE` | `ask` | `ask` requires `"confirm": true` on every mutating call. `direct` drops that requirement. Any other value falls back to `ask` semantics and is reported as a problem by `doctor`. |
| `MAC_CALENDAR_MAX_BODY_CHARS` | `8000` | Cap on notes text returned by read tools. Longer values are truncated with an explicit marker and a `…Truncated: true` flag. |
| `MAC_CALENDAR_DEFAULT_LIMIT` | `50` | Default `limit` for list tools. |
| `MAC_CALENDAR_MAX_LIMIT` | `500` | Hard ceiling on `limit`, and on how many reminders a single batch operation may touch. |
| `MAC_CALENDAR_AUTO_REQUEST_ACCESS` | `true` | Show the macOS consent dialog lazily, the first time an operation needs Calendar or Reminders access. Set to `false` for scripted use where a dialog would be unwelcome. |
| `MAC_CALENDAR_SDK` | auto | Build-time only: forces a specific SDK for `scripts/build.sh`. |
| `MAC_CALENDAR_SIGN_IDENTITY` | `-` | Build-time only: the codesign identity. Ad-hoc signing changes the cdhash on every rebuild, which can invalidate an earlier TCC grant. |

Local preferences written by `calendars_set_default` live in
`~/Library/Application Support/mac-calendar-bridge/preferences.json`. They hold
only container identifiers and a time zone — no calendar content.

## Permission model

Calendar and Reminders are separate TCC services, and both need **Full Access**
for the read paths to work. `EKAuthorizationStatus` values are reported verbatim:
`notDetermined`, `restricted`, `denied`, `fullAccess`, `writeOnly`.

The important subtlety is attribution: macOS grants access to the **responsible
process**, which is the app that launched the bridge (Codex, ChatGPT.app, or the
terminal), not the bridge itself. Two consequences:

- The grant must be made for that app, in System Settings › Privacy & Security ›
  Calendars (and › Reminders). The same binary run from a terminal and from Codex
  sees two different permission states, because they are two different responsible
  processes.
- Rebuilding the binary can invalidate an existing grant when it is ad-hoc signed,
  so `calendars_status` should be re-checked after a rebuild.

Because that attribution is easy to miss, the bridge does not wait for the caller
to know about it: `requireRead` / `requireWrite` trigger the native consent dialog
when the status is still `notDetermined`, before failing
(`MAC_CALENDAR_AUTO_REQUEST_ACCESS=false` disables this). The dialog cannot appear
in a session with no GUI, so a headless run must rely on a grant made earlier from
the desktop app or System Settings.

`calendars_status` reports `ready`, a `blockers` list, both deep links, and a
`remedy` string. `calendars_request_access` re-triggers the dialog but cannot
re-show it once macOS has recorded a denial.

## Result envelope

Every tool returns one of two shapes, with `ok` deciding which:

```jsonc
{ "ok": true, "tool": "calendar_list_events", "count": 3, "events": [ /* … */ ] }
```

```jsonc
{ "ok": false, "tool": "calendar_get_event",
  "error": { "code": "not_found", "message": "…", "hint": "…" } }
```

`hint` is always an actionable next step. In the MCP layer a failed call sets
`isError: true` while still returning parseable structured content.

### Error codes

| Code | Meaning | Usual fix |
| --- | --- | --- |
| `invalid_argument` | A parameter is missing, malformed, or contradictory. | Read the `hint`; date-parsing failures list the accepted formats. |
| `permission_denied` | Calendar or Reminders Full Access is missing. | `calendars_open_privacy_settings`, then `calendars_status`. |
| `not_found` | No event, reminder, calendar, or list matches. | List first; ids and names are echoed with the available options. |
| `ambiguous_target` | Several containers match a name. | Re-issue with `calendar_id` / `list_id`. |
| `unsupported` | The operation is invalid for that container or data model — read-only calendar, invitations, location alarms on an account that does not support them. | The `hint` names the alternative. |
| `operation_failed` | EventKit rejected the write. | The message carries EventKit's own description. |

### The write contract, precisely

Mutating tools take two flags:

- `dry_run: true` — always returns `applied: false` with the resolved target and
  never touches EventKit, whatever the write mode is.
- `confirm: true` — required while the mode is `ask`. Without it the call returns
  `applied: false`, `allowed: false`, `needsConfirm: true`, the resolved target,
  and (for updates) the `before` state.

Both flags default to absent, so an under-specified call changes nothing. Delete
tools for containers additionally require `confirm_delete_contents: true` when the
container is non-empty, and the refusal reports the counts.

## Date handling

Accepted inputs, tried in this order:

- ISO-8601, with or without a zone: `2026-10-10T15:00:00+08:00`,
  `2026-10-10T15:00`, `2026-10-10 15:00`.
- Calendar formats: `2026-10-10`, `2026/10/10`, `2026.10.10`, `2026年10月10日`,
  and year-less `10-10` / `10/10`.
- Relative offsets: `+90m`, `-2h`, `+3d`, `in 2 hours`, `2 hours from now`,
  `3 天后`, `30分钟后`, `1周后`.
- Day words: `today`, `tomorrow`, `yesterday`, `day after tomorrow`, `今天`,
  `明天`, `昨天`, `后天`, `前天`, optionally followed by a clock time.
- Weekdays: `monday` … `sunday`, `mon`, `下周三`, `上周五`, `next monday 09:00`.
  Weeks use ISO semantics (Monday first), so a bare weekday that already passed
  this week resolves to the coming one.
- Clock times: `15:00`, `9:30`, `15:00:00`, `下午3点`, `18时`.

Output carries `iso` (with offset), `local` (`2026-10-10 15:00 Sat`),
`epochSeconds`, and the zone identifier. Date-only inputs become all-day items;
`reminders_create` additionally reports `dateOnly` so an all-day due date is not
mistaken for midnight.

`mac-calendar-bridge parse-date '<expression>'` shows exactly how an expression
resolves — useful when a natural-language phrase lands on an unexpected day.

## All-day events

EventKit stores an all-day event with an **inclusive** end: it snaps whatever end
date it is given to 23:59:59 of the day that date falls in. The timed convention
(`end = start + 1 day`, exclusive) therefore produces an event one day too long —
a single-day all-day event silently becomes two days.

This bridge uses one consistent rule instead:

- `end` names the **last day the event covers, inclusive**. Omitting it means a
  single day, and `end` equal to `start` also means one day.
- `duration_minutes` is rounded up to whole days (1440 → one day, 4320 → three).
- On read, all-day events report `startDate` and `endDate` as plain `yyyy-MM-dd`
  values, plus `durationDays`. `durationMinutes` is `durationDays * 1440`, so a
  one-day event never reports a puzzling 1439. The raw stored values remain in
  `start` / `end`, and `endIsInclusiveLastDay: true` marks the convention
  explicitly.

```jsonc
{ "title": "Conference", "start": "2026-11-15", "all_day": true }
// → startDate 2026-11-15, endDate 2026-11-15, durationDays 1

{ "title": "Trip", "start": "2026-11-15", "end": "2026-11-17", "all_day": true }
// → startDate 2026-11-15, endDate 2026-11-17, durationDays 3
```

On read the parser also tolerates the opposite convention, so an all-day event
synced from a server that reports an exclusive midnight still yields the right day
count.

The same rule applies to `calendar_quick_add`, which additionally strips an all-day
keyword such as `全天` or `all day` out of the title.

## Recurrence

```jsonc
{ "frequency": "weekly", "interval": 1, "days_of_week": ["mo", "we", "fr"], "count": 10 }
{ "frequency": "monthly", "days_of_month": [1, 15], "until": "2026-12-31" }
{ "frequency": "monthly", "days_of_week": ["tu#2"] }   // second Tuesday
```

`frequency` is required. `count` and `until` are mutually exclusive. Passing a
`recurrence` array replaces the existing rules; passing `[]` makes the item
non-recurring, as does `"clear": ["recurrence"]`.

Editing a recurring event requires `occurrence_date` to pick the occurrence and
`span` to choose the reach: `this`, `this_and_future`, or `all`. EventKit shares
one identifier across a series, which is why the occurrence date is needed.

## Alarms

```jsonc
[{ "minutes_before": 15 }]
[{ "at": "2026-10-10T09:00:00+08:00" }]
[{ "location": { "title": "Office", "latitude": 31.2304, "longitude": 121.4737, "radius": 150, "on": "enter" } }]
```

The array replaces all existing alarms. Geofence alarms require an account that
supports structured locations; iCloud and local containers do, Exchange and some
CalDAV servers do not, and the failure is reported as `unsupported` with that
explanation.

## Architecture

```
CLI / MCP server  ──┐
                    ├─→ Tools.swift        registry: names, JSON schemas, dispatch
                    │        │
                    │        └─→ writeGuard (Support.swift)
                    │
                    └─────────→ Store (+ Events / Reminders / Containers extensions)
                                     │
                                     └─→ EventKit
```

- **Tools.swift** is the single source of truth for the tool surface. Both the MCP
  server and the CLI dispatch through `runTool`, so anything an agent can do is
  reproducible from a shell, and `tools --markdown` regenerates the docs.
- **Store** and its extensions own every EventKit call and return
  `[String: Any]` ready for JSON. Nothing above them imports EventKit.
- **Support.swift** holds the write guard, argument coercion, error taxonomy, and
  JSON helpers. `EventKitSupport.swift` holds the safe accessors for EventKit's
  `null_unspecified` properties, which Swift surfaces as optionals and which must
  never be boxed into a result unmodified.

## Free/busy computation

`calendar_find_free_slots` merges overlapping busy intervals per day, then
subtracts them from the working window (`workday_start`–`workday_end`, default
09:00–18:00). Events marked `free` are ignored unless `include_free_events` is set;
all-day events block the whole day unless `all_day_blocks` is false;
`min_lead_minutes` excludes slots starting too soon. `calendar_event_conflicts`
reports overlapping pairs with the overlap window in minutes.

## Testing

`scripts/smoke.sh` is the end-to-end check: it creates a temporary calendar in the
local account and a temporary reminder list, exercises read, write, guard, and
refusal paths, and removes both containers in a `trap`. It is safe to run
repeatedly. `--list-only` restricts it to read paths, `--keep` leaves the
containers for inspection.

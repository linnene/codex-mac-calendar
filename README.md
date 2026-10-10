<img src="plugins/mac-calendar/assets/composer-icon.png" width="88" alt="">

# codex-mac-calendar

A [Codex](https://github.com/openai/codex) plugin that gives the agent direct
control of this Mac's **Calendar** and **Reminders**, so calendar work happens in
chat instead of in Calendar.app.

```
"我今天有什么安排"                    → calendar_agenda
"明天下午3点和设计组评审1小时"          → calendar_quick_add
"建一个叫旅行的日历，用青绿色"          → calendar_create_calendar
"这周什么时候有连续两小时的空档"        → calendar_find_free_slots
"哪些提醒事项已经逾期了"                → reminders_list --overdue_only
```

One Swift binary talks to EventKit. It is exposed twice: as an MCP tool server for
Codex, and as a CLI for you. Because it is a plain MCP server, any MCP client can
use it, not just Codex.

## Requirements

- macOS 14 or newer. Developed and tested on macOS 26.6.
- Xcode Command Line Tools — no full Xcode needed:
  `xcode-select --install`
- Codex with plugin support (`codex plugin --help` should work).

## Quick start

```bash
git clone https://github.com/linnene/codex-mac-calendar.git
cd codex-mac-calendar
./scripts/install.sh
```

That builds the binary, registers this repository as a Codex plugin marketplace,
and installs the `mac-calendar` plugin from it. Then **restart Codex**.

## Granting access (the step that trips everyone up)

macOS does not grant Calendar or Reminders access to a plugin. It grants it to the
**app that launched the process**. The bridge runs as a child of whatever started
Codex, so the permission has to be given to that app — and a grant made to one app
does not help another. Running the same binary from your terminal and from Codex
gives two independent permission states.

Which app is it? Ask the bridge:

```bash
./plugins/mac-calendar/bin/mac-calendar-bridge status
```

If you are running that from a terminal, it reports the *terminal's* access. To see
what Codex itself gets, ask Codex to call `calendars_status`. In practice the
responsible app is usually:

- the Codex or ChatGPT desktop app, when Codex runs as part of it, or
- your terminal, when you run `codex` from a shell.

Then:

1. Open **System Settings › Privacy & Security › Calendars** and enable **Full
   Access** for that app. Do the same under **› Reminders**.
2. **Quit that app completely and reopen it.** A long-running app keeps the
   permission decision it made at launch, so it will keep reporting the old state
   until it restarts.
3. Re-check with `mac-calendar-bridge status` or by asking Codex to call
   `calendars_status`.

The bridge triggers the macOS consent dialog automatically the first time an
operation needs access, so usually you only have to click Allow. If no dialog
appears, macOS has already recorded a decision — only System Settings can change it
after that.

**Add-Only is not enough** for Calendars. Reading events and editing calendar
colours both require Full Access.

A headless run (`codex exec` in a script, a cron job, an SSH session) usually
cannot draw the dialog at all. Grant access once from the desktop, and the headless
runs inherit it.

## Verify it works

```bash
B=plugins/mac-calendar/bin/mac-calendar-bridge

$B status                                   # permissions, accounts, defaults
$B doctor                                   # environment checks
$B call calendar_agenda --arg range=today   # what is on today
$B tools                                    # the whole catalogue
```

A healthy `status` starts with `"ready" : true`.

To check the whole surface against your real databases:

```bash
./scripts/smoke.sh
```

It creates a temporary calendar and reminder list, exercises the read, write, guard,
and refusal paths, and deletes both containers again even if something fails. Safe
to run repeatedly. `--list-only` restricts it to read paths; `--keep` leaves the
containers for inspection.

## Using it

From chat, just ask. The bundled skill teaches the agent when to reach for which
tool, so "what does my week look like" becomes `calendar_agenda` and "remind me to
renew the passport in March" becomes `reminders_create` with a due date.

From a shell, the CLI reaches the identical tool surface:

```bash
B=plugins/mac-calendar/bin/mac-calendar-bridge

$B call calendar_agenda --arg range=this_week --pretty
$B call calendar_list_events --arg calendar='Work' --arg range=today
$B call calendar_search_events --arg query=invoice --arg start=2026-01-01 --arg end=2026-12-31
$B call calendar_find_free_slots --arg range=tomorrow --arg duration_minutes=90

$B call calendar_quick_add --arg text='明天下午3点和设计组评审1小时' --arg confirm=true
$B call calendar_create_event --arg calendar=Work --arg title='Standup' \
      --arg start='tomorrow 09:30' --arg duration_minutes=30 \
      --arg alarms='[{"minutes_before":10}]' \
      --arg recurrence='[{"frequency":"weekly","days_of_week":["mo","we","fr"]}]' \
      --arg confirm=true

$B call reminders_create --arg list=Inbox --arg title='写周报' \
      --arg due='明天 18:00' --arg priority=high --arg remind_at_minutes=60 --arg confirm=true
$B call reminders_complete --arg ids='["<id>","<id>"]' --arg confirm=true

$B call calendar_create_calendar --arg title=Travel --arg color=teal --arg confirm=true
$B call calendars_color_palette

$B parse-date '下周三 15:00'          # check how a date expression resolves
echo '{"range":"this_week"}' | $B call calendar_agenda - --pretty
```

Dates accept ISO-8601 and natural language: `tomorrow 18:00`, `+90m`,
`in 2 hours`, `3 天后`, `下周三 15:00`, `next monday 09:00`. Weeks resolve with ISO
semantics (Monday first), so `下周三` means the same thing regardless of locale.

### Using it with another MCP client

The plugin manifest is Codex packaging only. The server itself is generic:

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

## What is included

35 tools, all reachable from chat and from the CLI.

- **Diagnostics** — permission status with the exact remedy, accounts, colour
  palette, the System Settings deep link.
- **Calendars (event groups)** — list, create, rename, recolour, delete, pin a
  default.
- **Reminder lists** — the same.
- **Events** — list and search over any range, full detail, create, update, delete,
  move between calendars, duplicate, conflict detection, free-slot search, and
  natural-language quick add.
- **Reminders** — list and filter by list, due range, status, priority or keyword,
  create, update, complete, reopen, move, delete.
- **Combined** — `calendar_agenda` merges events and due reminders, including
  overdue ones, into one time-ordered timeline.

Full argument reference: [docs/tools.md](docs/tools.md) (generated from the
schemas) and [docs/reference.md](docs/reference.md).

## Safety model

- **Confirmation.** Mutating tools write nothing unless the request carries
  `"confirm": true`. Without it you get a preview and `needsConfirm: true`.
- **Host approval.** Codex additionally asks the user before structural or
  destructive changes — creating, renaming, recolouring, or deleting a calendar or
  list, deleting events, moving events or reminders between containers, and
  changing defaults. Configured in
  [`plugins/mac-calendar/.mcp.json`](plugins/mac-calendar/.mcp.json).
- **Dry run.** `"dry_run": true` never writes, in any mode.
- **Non-empty containers.** Deleting a calendar or list that still holds items is
  refused unless `"confirm_delete_contents": true` accompanies it, and the refusal
  reports how many items are at stake.
- **Read-only containers.** Subscribed calendars, the birthday calendar, and shared
  read-only containers are refused with an explanation rather than an EventKit
  error.
- **No guessing.** A container name matching more than one calendar or list raises
  `ambiguous_target` instead of picking one.
- **Nothing is retried blindly.** Every error carries a `hint` naming the next
  action.

Set `MAC_CALENDAR_WRITE_MODE=direct` to drop the confirmation requirement. The host
approval prompts remain.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `MAC_CALENDAR_WRITE_MODE` | `ask` | `ask` requires `"confirm": true` on every mutating call. `direct` drops that requirement. |
| `MAC_CALENDAR_MAX_BODY_CHARS` | `8000` | Cap on notes text returned by read tools. |
| `MAC_CALENDAR_DEFAULT_LIMIT` | `50` | Default `limit` for list tools. |
| `MAC_CALENDAR_MAX_LIMIT` | `500` | Hard ceiling on `limit` and on batch sizes. |
| `MAC_CALENDAR_AUTO_REQUEST_ACCESS` | `true` | Show the macOS consent dialog lazily on first use. Set `false` for scripted use where a dialog would be unwelcome. |
| `MAC_CALENDAR_SDK` | auto | Build time only: force a specific SDK path. |
| `MAC_CALENDAR_SIGN_IDENTITY` | `-` | Build time only: codesign identity. |

## Things EventKit cannot do

These are platform limits. The tools say so explicitly instead of pretending
otherwise.

- **Invitees cannot be added.** Attendees are read-only in EventKit.
  `calendar_create_event_in_calendar_app` works around it by writing a temporary
  `.ics` and opening it in Calendar.app, where you can add people and save.
- **Reminders have no "flagged" flag.** EventKit exposes no such property;
  `priority` is the supported signal, and `flagged: true` is an explicit error.
- **The system default calendar and list cannot be changed** by any API.
  `calendars_set_default` pins a default inside this bridge instead.
- **A calendar cannot move between accounts.** Create it in the target account and
  move the events across.
- **Reminders subtasks are not exposed** to third-party apps.

## Troubleshooting

**`ready: false` / `permission_denied`** — the app running Codex lacks Full Access.
See [Granting access](#granting-access-the-step-that-trips-everyone-up). Rebuilding
the binary can also invalidate an earlier grant, so re-check after a version change.

**Tools do not appear in Codex at all** — restart Codex. If they still do not
appear, check `codex plugin list` and `codex mcp list`; `mac_calendar` should be
listed as enabled. `./scripts/install.sh --check` shows what is registered.

**`codex plugin add` says the marketplace is unknown** — run
`codex plugin marketplace list` and confirm the repository root is listed, then
retry.

**The build fails with `SDK is not supported by the compiler`** — Command Line
Tools ships SDKs that do not always match the installed `swiftc`.
`scripts/build.sh` probes for a working pairing automatically; override it with
`MAC_CALENDAR_SDK=/path/to/MacOSX.sdk ./scripts/build.sh`.

**An all-day event covers one day too many** — fixed in `0.1.1`. EventKit snaps an
all-day end date to the end of the day it falls in, so `end` is the *inclusive*
last day. Update to the current version.

**An all-day event comes back as `allDay: false` with no `startDate`/`durationDays`**
— fixed in `0.1.2`. A date-only `start` used to create a timed event despite the
shape of the result, so the item existed but was not all-day. Update to the current
version.

**`calendar_create_event` fails with "The end time must be after the start time"**
— fixed in `0.1.2`. A create with a future `start` and neither `end` nor
`duration_minutes` used to default its end to *now*, which is already in the past.
Pass `duration_minutes` as a workaround on older versions.

**An all-day event becomes a timed event when `timezone` is passed** — fixed in
`0.1.3`. Attaching a time zone to an event made EventKit drop the all-day flag,
and all-day day boundaries were computed in the requested zone rather than the
system zone. Omit `timezone` as a workaround on older versions.

**Dates land on the wrong day** — run `mac-calendar-bridge parse-date '<text>'` to
see how the expression resolves, and pass an explicit `timezone` if the machine
default is not what you meant.

## Updating and uninstalling

```bash
git pull
./scripts/install.sh          # rebuild and reinstall
```

```bash
codex plugin remove mac-calendar
codex plugin marketplace remove mac-calendar-local
```

`calendars_set_default` writes one small preferences file in
`~/Library/Application Support/mac-calendar-bridge/`. It holds container
identifiers only, no calendar content.

## Development

```bash
./scripts/build.sh       # build (probes for a usable SDK)
./scripts/smoke.sh       # 145 end-to-end assertions against real databases
./scripts/make-docs.sh   # regenerate docs/tools.md from the schemas
./scripts/make-assets.sh # regenerate the icon set
```

The build script exists because Command Line Tools ships an SDK that is sometimes
newer than the local `swiftc`, and compiling against it fails outright. The script
probes each installed SDK with a trivial compile and uses the first that works.

### Layout

```
.agents/plugins/marketplace.json        marketplace entry point for Codex
plugins/mac-calendar/
  .codex-plugin/plugin.json             plugin manifest and UI metadata
  .mcp.json                             MCP server and per-tool approval policy
  skills/mac-calendar/SKILL.md          behaviour rules the agent reads
  assets/                               generated icon set
  bin/                                  built binary (gitignored)
Sources/MacCalendarBridge/
  main.swift            entry point
  CLI.swift             command line surface
  MCP.swift             stdio JSON-RPC MCP server
  Tools.swift           tool registry: names, schemas, dispatch
  Store.swift           EventKit core: permissions, accounts, containers
  Events.swift          events, recurrence, alarms, free/busy, quick add
  Reminders.swift       reminders and the merged agenda
  Containers.swift      container CRUD, diagnostics, .ics handoff
  Dates.swift           date parsing and rendering
  Colors.swift          colour palette and hex round-tripping
  Preferences.swift     the bridge's own default containers
  Support.swift         errors, arguments, write guard, JSON
  EventKitSupport.swift safe accessors for EventKit's null-unspecified fields
scripts/                build, install, smoke, docs, assets
docs/                   reference.md and generated tools.md
```

## License

MIT — see [LICENSE](LICENSE).

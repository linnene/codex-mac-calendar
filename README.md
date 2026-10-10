# codex-mac-calendar

A Codex plugin that gives the agent direct control of this Mac's **Calendar** and
**Reminders** databases, so calendar work happens in chat instead of in
Calendar.app.

It is a single Swift binary (`mac-calendar-bridge`) that speaks EventKit and is
exposed two ways: as an MCP tool server for Codex, and as a CLI for you.

```
"把我这周的空闲时间整理一下"          → calendar_find_free_slots
"明天下午3点和张伟开会1小时"            → calendar_quick_add
"建一个叫旅行的日历，用青绿色"          → calendar_create_calendar
"哪些提醒事项已经逾期了"                → reminders_list --overdue_only
```

## Requirements

- macOS 14 or newer (EventKit's Full Access API). Developed and tested on macOS 26.6.
- Xcode Command Line Tools (`xcode-select --install`) — no full Xcode needed.
- Codex with plugin support (`codex plugin`).

## Install

```bash
git clone <this repo> ~/dev/codex-mac-calendar
cd ~/dev/codex-mac-calendar
./scripts/install.sh
```

The script builds the binary, registers this repository as a Codex plugin
marketplace, and installs the `mac-calendar` plugin from it. Then restart Codex.

Verify by hand at any point:

```bash
./plugins/mac-calendar/bin/mac-calendar-bridge status
./scripts/install.sh --check          # what Codex currently has registered
```

### Granting access

macOS attributes Calendar and Reminders access to the **app that launched the
process** — Codex, ChatGPT.app, or your terminal — not to this plugin. So the
grant goes on that app:

1. `mac-calendar-bridge permissions` triggers the native prompts.
2. If nothing appears (a previous denial is remembered), open
   System Settings › Privacy & Security › **Calendars** and › **Reminders** and
   enable **Full Access** for the app running Codex.
3. `mac-calendar-bridge status` reports exactly what is missing and prints the
   deep links to the right panes.

Add-Only access for Calendars is not enough: reading events and editing calendar
colours both need Full Access. Rebuilding the helper can invalidate an earlier
grant, so re-check `status` after a rebuild.

## Tools

35 tools, all reachable from chat and from the CLI.

**Diagnostics** — `calendars_status`, `calendars_request_access`,
`calendars_open_privacy_settings`, `calendars_list_accounts`,
`calendars_color_palette`

**Calendars (event groups)** — `calendar_list_calendars`,
`calendar_create_calendar`, `calendar_update_calendar`,
`calendar_delete_calendar`, `calendars_set_default`

**Reminder lists** — `reminders_list_lists`, `reminders_create_list`,
`reminders_update_list`, `reminders_delete_list`

**Events** — `calendar_list_events`, `calendar_search_events`,
`calendar_get_event`, `calendar_create_event`, `calendar_update_event`,
`calendar_delete_event`, `calendar_move_event`, `calendar_duplicate_event`,
`calendar_quick_add`, `calendar_event_conflicts`, `calendar_find_free_slots`,
`calendar_create_event_in_calendar_app`

**Reminders** — `reminders_list`, `reminders_get`, `reminders_create`,
`reminders_update`, `reminders_complete`, `reminders_uncomplete`,
`reminders_delete`, `reminders_move`

**Combined** — `calendar_agenda` merges events and due reminders, including
overdue ones, into one time-ordered timeline.

Full argument reference: [docs/reference.md](docs/reference.md).

## Safety model

- **Confirmation.** Mutating tools do nothing unless the request carries
  `"confirm": true`; without it they return a preview and `needsConfirm: true`.
  Routine event and reminder writes go through on the second call.
- **Host approval.** Codex additionally asks the user before structural or
  destructive changes: creating, renaming, recolouring, or deleting a calendar or
  list, deleting events, moving events between calendars, moving reminders, and
  changing defaults. Configured in
  [`.mcp.json`](plugins/mac-calendar/.mcp.json).
- **Dry run.** `"dry_run": true` never writes, in any mode.
- **Non-empty containers.** Deleting a calendar or list that still holds items is
  refused unless `"confirm_delete_contents": true` accompanies it, and the refusal
  reports how many items are at stake. Moving the items first is offered as the
  alternative.
- **Read-only containers.** Subscribed calendars, the birthday calendar, and
  shared read-only containers are refused with an explanation instead of an
  EventKit error.
- **No guessing.** A container name that matches more than one calendar or list
  produces `ambiguous_target`, never a silent pick.
- **Irreversibility is stated.** Deletes sync to every device on the account.

Set `MAC_CALENDAR_WRITE_MODE=direct` to drop the confirmation requirement (the
approval prompts in `.mcp.json` remain).

## Usage

From chat, just ask. From a shell:

```bash
B=plugins/mac-calendar/bin/mac-calendar-bridge

$B tools                                     # the whole catalogue
$B call calendar_agenda --arg range=today --pretty
$B call calendar_list_events --arg calendar='工作' --arg range=this_week
$B call calendar_quick_add --arg text='下周三下午2点和设计组评审30分钟' --arg confirm=true
$B call reminders_create --arg list=科研任务 --arg title='写周报' --arg due='明天 18:00' --arg priority=high --arg confirm=true
$B call calendar_create_calendar --arg title=旅行 --arg color=teal --arg confirm=true
$B parse-date '下周三 15:00'                  # check a date expression
echo '{"range":"this_week","include_reminders":true}' | $B call calendar_agenda - --pretty
```

Dates accept ISO-8601 and natural language: `tomorrow 18:00`, `+90m`,
`in 2 hours`, `3 天后`, `下周三 15:00`, `next monday 09:00`. Weeks resolve with ISO
semantics (Monday first) so `下周三` means the same thing regardless of locale.

## Known limitations

These are EventKit limitations, and the tools say so explicitly rather than
pretending otherwise.

- **Invitees cannot be added.** Attendees are read-only in EventKit.
  `calendar_create_event_in_calendar_app` covers this by writing a temporary
  `.ics` and opening it in Calendar.app, where the user can add people and save.
- **No "flagged" on reminders.** EventKit exposes no such property; `priority` is
  the supported signal, and `flagged: true` returns an explicit error.
- **The system default calendar/list cannot be changed** by any API.
  `calendars_set_default` pins a default inside this bridge instead.
- **A calendar cannot move between accounts.** Create it in the target account and
  move the events across.
- **Reminders subtasks are not exposed** to third-party apps.
- **Deletes are permanent** in the sense that they propagate; there is no undo
  beyond the account's own history.

## Repository layout

```
.agents/plugins/marketplace.json        marketplace entry point for Codex
plugins/mac-calendar/
  .codex-plugin/plugin.json             plugin manifest and UI metadata
  .mcp.json                             MCP server + per-tool approval policy
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
scripts/
  build.sh              build the binary (probes for a usable SDK)
  install.sh            build + register + install into Codex
  smoke.sh              self-contained end-to-end test with cleanup
  make-assets.sh        regenerate the icons
  make-icon.swift       the icon artwork, as code
docs/reference.md       full tool and configuration reference
```

## Development

```bash
./scripts/build.sh      # build
./scripts/smoke.sh      # 90 end-to-end assertions; creates temp containers and removes them
./scripts/smoke.sh --keep        # leave the temp containers for inspection
./scripts/smoke.sh --list-only   # read paths only
```

`smoke.sh` creates a temporary calendar in the local account and a temporary
reminder list, exercises the whole surface, and deletes both in a `trap` — it is
safe to run repeatedly and leaves nothing behind.

### The SDK quirk

`scripts/build.sh` exists because Command Line Tools on this machine ships
`MacOSX27.sdk` (built with Swift 6.4) alongside a 6.3.3 compiler, and compiling
against the newer SDK fails outright. The script probes each installed SDK with a
trivial compile and uses the first one that works. Override with
`MAC_CALENDAR_SDK=/path/to/MacOSX.sdk`.

## License

MIT

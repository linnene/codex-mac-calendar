---
name: mac-calendar
description: Use when the user asks about their calendar, schedule, meetings, agenda, availability, or their to-dos on this Mac. Covers reading, creating, editing, moving, completing, and deleting events and reminders, plus creating, renaming, recolouring, and deleting calendars and reminder lists. Triggers on "add to my calendar", "what's on today", "schedule a meeting", "remind me to", "when am I free", "my tasks", and the equivalents 日程, 日历, 提醒事项, 待办, 安排, 空闲时间.
---

# Mac Calendar & Reminders

You are operating the user's real Calendar and Reminders data on this Mac through
EventKit. Changes sync to every device signed into the same account, so treat
every write as durable and visible.

## Start here

Run `calendars_status` before anything else in a session. It reports both TCC
permissions, the accounts, the default containers, and the exact remedy for a
missing permission. If it returns `ready: false`, fix that first — do not attempt
the calendar work anyway, and do not look for a shell workaround.

## Always resolve containers before writing

Run `calendar_list_calendars` or `reminders_list_lists` and use the exact `id`.
The write tools accept a name, but names repeat (two accounts can both have a
list called "Personal"), and a wrong container is the worst outcome here. The
bridge refuses an ambiguous name with `ambiguous_target` rather than guessing —
when you see that, list the containers and pass `calendar_id` / `list_id`.

## The write contract

Every mutating tool behaves the same way:

- Writes do nothing until the request carries `"confirm": true`. Without it you
  get `applied: false`, `needsConfirm: true`, and a preview of what would change.
  Read the preview, then re-issue the identical call with `confirm: true`.
- `"dry_run": true` never writes, in any mode.
- Read-only, subscribed, and birthday containers are refused with an explicit
  message. Do not retry against them; pick a writable container.
- Deleting a calendar or list that still contains items is refused unless you also
  pass `"confirm_delete_contents": true`. Prefer `calendar_move_event` or
  `reminders_move` when the items should survive.
- `before` / `after` are returned for updates so you can tell the user what
  actually changed. Use them rather than restating your intent.

Some tools also carry a host-level approval prompt (container create/rename/
delete, event and reminder deletion, moves, and default changes). If the user
declines, stop and ask what they want instead.

## Routing

| The user wants | Use |
| --- | --- |
| "What does my day/week look like" | `calendar_agenda` — events and due reminders merged, including overdue |
| "When am I free" | `calendar_find_free_slots` |
| "Am I double-booked" | `calendar_event_conflicts` |
| "What's on \<some date\>" | `calendar_list_events` with `range` or `start`/`end` |
| "Find the event about X" | `calendar_search_events` (searches backwards and forwards) |
| A phrase they typed, dates included | `calendar_quick_add` |
| Details of one event | `calendar_get_event` |
| Create/move/edit/delete an event | `calendar_create_event`, `calendar_move_event`, `calendar_update_event`, `calendar_delete_event` |
| Invite other people | `calendar_create_event_in_calendar_app` |
| Their to-dos | `reminders_list` |
| Add/complete/reopen/move/delete to-dos | `reminders_create`, `reminders_complete`, `reminders_uncomplete`, `reminders_move`, `reminders_delete` |
| A new or renamed group, or a colour | `calendar_create_calendar` / `calendar_update_calendar` for calendars; `reminders_create_list` / `reminders_update_list` for reminder lists |
| Which colours are available | `calendars_color_palette` |

## Dates

- Pass dates as ISO-8601, or as natural language: `2026-10-10T15:00`,
  `tomorrow 18:00`, `+90m`, `in 2 hours`, `3 天后`, `下周三 15:00`.
- Never invent a date. If the user says "next week", ask which day, or propose a
  specific day and have them confirm.
- Output always carries `iso`, a human `local` form with weekday, and the time
  zone. Read the `local` value back to the user instead of reformatting it
  yourself.
- A date-only value (`2026-10-10`) becomes an all-day item when creating. Pass an
  explicit time when a time matters. On update, a bare date never converts an
  existing timed event to all-day — say `all_day: true` when you mean it.
- With neither `end` nor `duration_minutes`, a created event lasts one hour.
- `calendar_quick_add` returns a `parsed` block with the date text it matched and
  where the duration came from. Show that to the user; it is the cheapest way for
  them to catch a misread phrase.

## All-day events

For an all-day event, `end` is the **last day it covers, inclusive**. Omit `end`
for a single-day event; `end` equal to `start` also means one day. Never pass
`start` plus one day to mean a single day — that produces a two-day event.

Read all-day events from `startDate`, `endDate` (both `yyyy-MM-dd`) and
`durationDays`. Do not compute their length from `start`/`end`; the stored end is
the last second of the final day, so that arithmetic gives 1439 minutes for a
one-day event.

## Recurring items

A recurring series shares one `id` across all its occurrences. To act on a single
occurrence, pass `occurrence_date` exactly as returned by `calendar_list_events`.
`span` then chooses the reach: `this` (default), `this_and_future`, or `all`.
Changing a series without a `span` affects that one occurrence only — say so
before doing it.

## Colours

`calendars_color_palette` lists the names Calendar.app itself uses. Accept either
a name (`orange`, `橙`) or a hex value (`#FF9500`). If the user asks for "a nice
colour" without specifying, pick one and state which — do not silently choose.

## Hard limits — state these plainly, do not improvise around them

- **Invitees cannot be added through EventKit.** Attendees are read-only. Use
  `calendar_create_event_in_calendar_app`, which opens a prefilled event in
  Calendar.app for the user to add people and save.
- **Reminders have no "flagged" flag in EventKit.** Use `priority` (`high`
  mirrors Reminders' high priority). Passing `flagged: true` is an explicit error.
- **There is no API for the macOS system default calendar or list.**
  `calendars_set_default` pins a default for this bridge only.
- **A calendar cannot be moved between accounts.** Create it in the target
  account and move the events across.
- **Reminders subtasks are not exposed** by EventKit.

## Permission problems

If a tool returns `permission_denied`, the app running Codex (not the plugin) lacks
Full Access. The bridge already shows the macOS consent dialog automatically the
first time a calendar or reminder operation runs, so the usual cause is a
previously recorded decision — macOS never asks twice.

Walk the user through it:

1. `calendars_open_privacy_settings` with `pane: "calendars"` (or `"reminders"`).
2. Enable Full Access for Codex, ChatGPT, or the terminal that launched it.
3. Re-run `calendars_status` to confirm.

`calendars_request_access` re-triggers the dialog if it is still undecided.

Do not try to work around a permission failure — no shell command, AppleScript, or
`osascript` fallback helps, because every route hits the same TCC check against the
same responsible app. Report the remedy and stop. Rebuilding the helper can also
invalidate an earlier grant, so re-check after a version change.

## Reporting back

- Give times in the user's own local form, with the weekday.
- Say which calendar or list an item landed in.
- When a tool returns `applied: false`, tell the user nothing changed and why.
- Do not dump raw JSON at the user unless they asked for it.
- When a result is truncated (`truncated: true`, `limitHint`), say so rather than
  implying it is complete.

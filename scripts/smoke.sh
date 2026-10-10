#!/usr/bin/env bash
# Self-contained smoke test for mac-calendar-bridge.
#
# Creates a temporary calendar and reminder list, exercises the read and write
# paths, verifies the write guard, then removes everything it created. Safe to
# run repeatedly; a trap cleans up even when an assertion fails.
#
# Usage: scripts/smoke.sh [--keep] [--list-only]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/plugins/mac-calendar/bin/mac-calendar-bridge"
KEEP=0
LIST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --list-only) LIST_ONLY=1 ;;
  esac
done

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found. Run scripts/build.sh first." >&2
  exit 1
fi

STAMP="$(date +%H%M%S)"
CAL_NAME="Bridge Smoke $STAMP"
LIST_NAME="Bridge Smoke Tasks $STAMP"
TMP="$(mktemp -d)"
CAL_ID=""
LIST_ID=""
pass=0
fail=0

cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    echo ""
    echo "kept: calendar '$CAL_NAME' (${CAL_ID:-none}), list '$LIST_NAME' (${LIST_ID:-none})"
    rm -rf "$TMP"
    return
  fi
  if [[ -n "$CAL_ID" ]]; then
    "$BIN" call calendar_delete_calendar --arg id="$CAL_ID" --arg confirm=true \
      --arg confirm_delete_contents=true >/dev/null 2>&1
  fi
  if [[ -n "$LIST_ID" ]]; then
    "$BIN" call reminders_delete_list --arg id="$LIST_ID" --arg confirm=true \
      --arg confirm_delete_contents=true >/dev/null 2>&1
  fi
  echo ""
  echo "cleaned up temporary containers"
  rm -rf "$TMP"
}
trap cleanup EXIT

field() { # field <json-file> <dotted.path>
  python3 - "$1" "$2" <<'PY'
import json, sys, functools
data = json.load(open(sys.argv[1]))
def walk(obj, key):
    if key.isdigit():
        return obj[int(key)]
    return obj[key]
try:
    print(functools.reduce(walk, sys.argv[2].split("."), data))
except Exception:
    print("")
PY
}

check() { # check <label> <json-file> <python-expression over `d`>
  local label="$1" file="$2" expr="$3"
  if python3 - "$file" "$expr" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = bool(eval(sys.argv[2]))
sys.exit(0 if ok else 1)
PY
  then
    printf '  \033[32mok\033[0m   %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %s\n' "$label"
    python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),indent=2,ensure_ascii=False)[:1200])' "$file"
    fail=$((fail + 1))
  fi
}

run() { # run <label> <tool> [json|--arg k=v ...]
  local label="$1"; shift
  local out
  out="$("$BIN" call "$@" 2>&1)"
  printf '%s' "$out" > "$TMP/last.json"
  if python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("ok") else 1)' "$TMP/last.json" 2>/dev/null; then
    printf '  \033[32mok\033[0m   %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %s\n' "$label"
    printf '%s\n' "$out" | head -14
    fail=$((fail + 1))
  fi
}

reject() { # reject <label> <tool> [json] — expects ok:true but applied:false or an error
  local label="$1"; shift
  local out
  out="$("$BIN" call "$@" 2>&1)"
  printf '%s' "$out" > "$TMP/last.json"
  if python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if (d.get("applied") is False or d.get("ok") is False) else 1)' "$TMP/last.json" 2>/dev/null; then
    printf '  \033[32mok\033[0m   %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %s\n' "$label"
    printf '%s\n' "$out" | head -14
    fail=$((fail + 1))
  fi
}

echo "== read-only =="
run "status"                calendars_status
check "access is ready"     "$TMP/last.json" "d['ready'] is True"
check "version reported"    "$TMP/last.json" "d['bridge']['version'] == '0.1.0'"
run "list tools"            calendars_status
run "list accounts"         calendars_list_accounts
run "list calendars"        calendar_list_calendars
check "calendars returned"  "$TMP/last.json" "d['count'] >= 1"
run "list reminder lists"   reminders_list_lists
check "lists returned"      "$TMP/last.json" "d['count'] >= 1"
run "colour palette"        calendars_color_palette
check "palette has 16"      "$TMP/last.json" "d['count'] == 16"
run "agenda today"          calendar_agenda --arg range=today
run "free slots tomorrow"   calendar_find_free_slots --arg range=tomorrow --arg duration_minutes=30
run "conflicts today"       calendar_event_conflicts --arg range=today
run "list events today"     calendar_list_events --arg range=today
if [[ "$LIST_ONLY" == "1" ]]; then
  echo ""
  echo "list-only run: $pass passed, $fail failed"
  exit $((fail > 0))
fi

echo ""
echo "== write guard =="
reject "create without confirm is refused" \
  calendar_create_calendar --arg title="$CAL_NAME"
reject "dry_run never writes" \
  calendar_create_calendar --arg title="$CAL_NAME" --arg dry_run=true --arg confirm=true
reject "unknown calendar is an error" \
  calendar_list_events --arg calendar="No Such Calendar $STAMP"
reject "unknown list is an error" \
  reminders_list --arg lists="No Such List $STAMP"

echo ""
echo "== containers =="
run "create calendar"  calendar_create_calendar --arg title="$CAL_NAME" --arg color=teal --arg account=Default --arg confirm=true
CAL_ID="$(field "$TMP/last.json" container.id)"
if [[ -z "$CAL_ID" ]]; then
  run "create calendar (retry in iCloud)" calendar_create_calendar --arg title="$CAL_NAME" --arg color=teal --arg account=iCloud --arg confirm=true
  CAL_ID="$(field "$TMP/last.json" container.id)"
fi
check "calendar has the chosen colour" "$TMP/last.json" "d['container']['colorHex'] == '#30B0C7'"
run "recolour calendar" calendar_update_calendar --arg id="$CAL_ID" --arg color=purple --arg confirm=true
check "colour changed"  "$TMP/last.json" "d['after']['colorHex'] == '#AF52DE'"
run "rename calendar"   calendar_update_calendar --arg id="$CAL_ID" --arg new_title="$CAL_NAME (renamed)" --arg confirm=true

run "create reminder list" reminders_create_list --arg title="$LIST_NAME" --arg color=green --arg confirm=true
LIST_ID="$(field "$TMP/last.json" container.id)"
if [[ -z "$LIST_ID" ]]; then
  run "create reminder list in iCloud" reminders_create_list --arg title="$LIST_NAME" --arg color=green --arg account=iCloud --arg confirm=true
  LIST_ID="$(field "$TMP/last.json" container.id)"
fi
check "list has the chosen colour" "$TMP/last.json" "d['container']['colorHex'] == '#34C759'"

echo ""
echo "== events =="
run "create event with alarm and recurrence" calendar_create_event \
  --arg calendar_id="$CAL_ID" --arg title="Standup" --arg start="tomorrow 09:30" \
  --arg duration_minutes=30 --arg notes="smoke test" --arg url="https://example.com" \
  --arg alarms='[{"minutes_before":10}]' \
  --arg recurrence='[{"frequency":"weekly","interval":1,"days_of_week":["mo","we","fr"],"count":5}]' \
  --arg confirm=true
EVENT_ID="$(field "$TMP/last.json" event.id)"
check "alarm recorded"      "$TMP/last.json" "d['event']['alarms'][0]['minutesBefore'] == 10"
check "recurrence recorded" "$TMP/last.json" "d['event']['recurrence'][0]['frequency'] == 'weekly'"
check "titled correctly"    "$TMP/last.json" "d['event']['title'] == 'Standup'"

run "get event"        calendar_get_event --arg id="$EVENT_ID"
run "list in calendar" calendar_list_events --arg calendar_id="$CAL_ID" --arg range=next_7_days --arg include_details=true
check "event is listed" "$TMP/last.json" "any(e['id'] == '$EVENT_ID' for e in d['events'])"

run "quick add natural language" calendar_quick_add \
  --arg calendar_id="$CAL_ID" --arg text="明天下午3点和张伟开会1小时" --arg timezone=Asia/Shanghai --arg confirm=true
check "duration parsed from text" "$TMP/last.json" "d['event']['durationMinutes'] == 60"
check "title parsed from text"    "$TMP/last.json" "d['event']['title'] == '和张伟开会'"
QUICK_ID="$(field "$TMP/last.json" event.id)"

run "update event" calendar_update_event --arg id="$QUICK_ID" --arg title="和张伟开会（改）" --arg duration_minutes=90 --arg confirm=true
check "duration updated" "$TMP/last.json" "d['after']['durationMinutes'] == 90"
check "before/after reported" "$TMP/last.json" "d['before']['title'] != d['after']['title']"

run "duplicate event" calendar_duplicate_event --arg id="$QUICK_ID" --arg offset_minutes=1440 --arg confirm=true
DUP_ID="$(field "$TMP/last.json" event.id)"

run "move event"    calendar_move_event --arg id="$DUP_ID" --arg calendar_id="$CAL_ID" --arg confirm=true
run "find conflicts" calendar_event_conflicts --arg range=next_7_days --arg calendar_id="$CAL_ID"
run "delete event"  calendar_delete_event --arg id="$DUP_ID" --arg confirm=true
check "deleted"     "$TMP/last.json" "d['applied'] is True"

echo ""
echo "== reminders =="
run "create reminder" reminders_create --arg list_id="$LIST_ID" --arg title="写周报" \
  --arg due="tomorrow 18:00" --arg priority=high --arg remind_at_minutes=60 --arg notes="smoke test" --arg confirm=true
REM_ID="$(field "$TMP/last.json" reminder.id)"
check "priority mapped"  "$TMP/last.json" "d['reminder']['priorityLabel'] == 'high'"
check "due date present" "$TMP/last.json" "d['reminder']['due']['local'] != ''"
check "alarm attached"   "$TMP/last.json" "d['reminder']['alarms'][0]['minutesBefore'] == 60"

run "create second reminder" reminders_create --arg list_id="$LIST_ID" --arg title="买咖啡豆" --arg due="friday" --arg confirm=true
REM2_ID="$(field "$TMP/last.json" reminder.id)"

run "list reminders"   reminders_list --arg lists="$LIST_NAME" --arg status=incomplete --arg include_details=true
check "two reminders"  "$TMP/last.json" "d['totalMatching'] == 2"
check "sorted by due"  "$TMP/last.json" "d['reminders'][0]['title'] == '写周报'"

run "get reminder"     reminders_get --arg id="$REM_ID"
run "complete batch"   reminders_complete --arg ids="[\"$REM_ID\",\"$REM2_ID\"]" --arg confirm=true
check "both completed" "$TMP/last.json" "d['count'] == 2"
run "list completed"   reminders_list --arg lists="$LIST_NAME" --arg status=completed
check "completed found" "$TMP/last.json" "d['totalMatching'] == 2"
run "uncomplete one"   reminders_uncomplete --arg id="$REM_ID" --arg confirm=true
run "update reminder"  reminders_update --arg id="$REM_ID" --arg due="next monday 09:00" --arg priority=low --arg confirm=true
check "priority lowered" "$TMP/last.json" "d['after']['priorityLabel'] == 'low'"
run "search reminders" reminders_list --arg query=咖啡 --arg lists="$LIST_NAME" --arg status=all
check "search hit"     "$TMP/last.json" "d['totalMatching'] == 1"

run "delete reminder"  reminders_delete --arg id="$REM2_ID" --arg confirm=true
check "deleted one"    "$TMP/last.json" "d['count'] == 1"

echo ""
echo "== blocked operations =="
reject "refuse non-empty calendar delete" \
  calendar_delete_calendar --arg id="$CAL_ID" --arg confirm=true
reject "refuse to write to a subscribed calendar" \
  calendar_create_event --arg calendar="中国大陆节假日" --arg title="x" --arg start="tomorrow 10:00" --arg confirm=true
reject "reminders flagged is unsupported" \
  reminders_create --arg list_id="$LIST_ID" --arg title="x" --arg flagged=true --arg confirm=true

echo ""
if [[ "$fail" == "0" ]]; then
  printf '\033[32m%s passed, 0 failed\033[0m\n' "$pass"
else
  printf '\033[31m%s passed, %s failed\033[0m\n' "$pass" "$fail"
fi
exit $((fail > 0))

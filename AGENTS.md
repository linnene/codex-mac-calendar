# Agent instructions

## What this repository is

A Codex plugin that exposes macOS Calendar and Reminders through EventKit. The
Swift sources under `Sources/MacCalendarBridge/` are the product; the
`plugins/mac-calendar/` directory is the Codex packaging around it.

## Before finishing any change

```bash
./scripts/build.sh     # must compile with zero warnings
./scripts/smoke.sh     # must end with "N passed, 0 failed"
```

`smoke.sh` writes to real Calendar and Reminders databases. It creates a
temporary calendar and reminder list, and a `trap` removes both even on failure.
If you add a test that writes, give it its own temporary container and extend the
trap — never write into a container the user already had.

## Invariants that must not regress

- Every mutating tool goes through `writeGuard`. No exceptions, including
  convenience wrappers.
- No tool writes to a container without checking `allowsContentModifications`,
  `isImmutable`, and `isSubscribed` first.
- Deleting a non-empty calendar or list requires `confirm_delete_contents: true`,
  and the refusal must report how many items would be destroyed.
- An ambiguous container name raises `ambiguous_target`. Never pick one.
- Every value placed in a `[String: Any]` must be JSON-encodable. EventKit's
  `null_unspecified` properties surface as optionals — use the `safeStart` /
  `safeEnd` / `safeOccurrence` / `safeIdentifier` accessors in
  `EventKitSupport.swift` rather than boxing an `Optional` into a result.
- Result payloads carry `before`/`after` for updates so a caller can report what
  actually changed.

## Style

- Plain, direct comments that explain *why*, not *what*. No filler doc comments.
- Tool descriptions are written for a model that has to choose between 35 tools:
  say when to use the tool and what the alternative is.
- Errors carry a `hint` that names the next action.
- Keep the CLI and the MCP server on the same tool registry. If a tool exists, it
  must be reachable both ways.

## Things to be careful about

- `scripts/build.sh` picks an SDK by probing; the default SDK on this machine does
  not match the compiler. Do not hardcode an SDK path.
- EventKit's Swift nullability comes from `EventKit.apinotes`, and
  `EKAuthorizationStatusAuthorized` aliases `.fullAccess`. Compare rather than
  switching on authorization status.
- TCC attributes access to the launching app, not to this binary. Permission
  failures are an environment problem, not a code problem — the tool layer must
  report the remedy instead of retrying.
- Never log, print, or commit the user's mail bodies, message text, event notes,
  or reminder notes. `MAC_CALENDAR_MAX_BODY_CHARS` exists to bound what leaves
  the database.

## Commit

Commit your work before finishing. Do not commit
`plugins/mac-calendar/bin/` (gitignored build output).

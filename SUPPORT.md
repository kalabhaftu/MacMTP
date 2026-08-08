# Support

macMTP reports unexpected application and MTP-operation errors by default when
a valid release DSN is embedded. Reporting can be disabled in Preferences;
local diagnostics remain available through macOS unified logging either way.

## Include With A Bug Report

- macMTP version and installation source
- macOS version and Mac architecture
- Android device model, Android version, and USB mode
- The exact operation that failed, including the directory path if relevant
- Whether the device was unlocked and whether Retry changed the result
- A short screen recording or screenshot when the UI state is misleading

Do not include Sentry auth tokens, DSNs, private files, or complete personal
directory paths in an issue. macMTP redacts paths from error reports.

## Capture Logs

Reproduce the problem, then run:

```bash
log show --last 10m \
  --predicate 'subsystem == "com.macmtp.app"' \
  --info --style compact
```

Attach only the relevant lines. Directory failures include the native MTP
operation and error type when the library provides them; blank native messages
are replaced with an actionable fallback.

## Transfer Semantics

Pause and resume apply at file boundaries because the upstream `go-mtpx`
transfer API exposes progress callbacks but no cancellation or pause handle for
the currently active file. A large file can therefore finish its current native
operation before the queue becomes idle. This is an upstream API boundary, not
a hidden retry loop in the UI.

## Security

Report security issues privately using [SECURITY.md](SECURITY.md), not a public
issue.

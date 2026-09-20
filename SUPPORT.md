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

Connection lifecycle lines are also written to Terminal. They use fields such
as `event`, `state`, `generation`, `attempt`, `operation`, `phase`, and
`usb_error`. A healthy launch normally looks like:

```text
MTP event=USB device availability changed level=info event=usb_scan state=device_found
MTP event=MTP connection attempt level=info event=connection_attempt state=connecting generation=1 attempt=1
MTP event=MTP connection established level=info event=connection_ready state=connected generation=1 attempt=1
```

After a transport failure, macMTP performs at most one controlled session
retry. Further retries require the Retry Connection button. Repeated
`OpenSession` or `GetDeviceInfo` lines without a new USB attach event indicate
a regression and should be reported.

On macOS, `ptpcamerad` and `mscamerad-xpc` can temporarily claim the phone's
MTP/PTP interface. After a failed handshake macMTP releases only those exact
process names and immediately retries once. It does not kill them before a
failure, and it does not use broad process-name matching.

For a phone connected before launch, keep it unlocked in File Transfer mode,
start macMTP, and wait for `Android device detected` before copying. Test both
a single file and a nested folder. A transfer failure should identify the
operation phase and payload bytes, for example:

```text
MTP operation=SendObject phase=data-payload sent=512 requested=512 packet=512
```

## Transfer Semantics

Pause and resume apply at file boundaries because the upstream `go-mtpx`
transfer API exposes progress callbacks but no cancellation or pause handle for
the currently active file. A large file can therefore finish its current native
operation before the queue becomes idle. This is an upstream API boundary, not
a hidden retry loop in the UI.

## Security

Report security issues privately using [SECURITY.md](SECURITY.md), not a public
issue.

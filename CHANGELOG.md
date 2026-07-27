# Changelog

## Unreleased

- Nothing yet.

## 1.6.5 - 2026-07-27

- Set anonymous crash and error reporting to enabled by default, maintaining user privacy controls in Preferences.
- Filtered expected hardware and device states (locked phone screen, charging-only mode, USB disconnects) from Sentry error logging to eliminate false-positive production alerts.
- Added clear, actionable user guidance when an Android phone screen is locked or USB mode is set to Charging Only ("No storage found on device. Please unlock your Android phone screen and ensure its USB connection mode is set to 'File Transfer' (MTP), then click Retry.").
- Conducted codebase cleanup by stripping redundant inline comments across all source files.

## 1.6.4 - 2026-07-26

- Added customizable Navigation Sidebar positioning, allowing the sidebar to be docked on either the Left or Right side of the window.
- Removed internal developer "Send Test Report" button from Preferences UI.
- Added direct "Report an Issue / Bug…" action in Preferences for user feedback and issue submission.

## 1.6.3 - 2026-07-26

- Fixed main-thread App Hanging in UpdaterService by converting synchronous runModal alert calls to non-blocking window sheet modals.
- Fixed error handling for GitHub update checks by adding diagnostic logging and clear messaging for HTTP 403 rate limits.
- Fixed file transfer error messages for write permission restrictions (NSCocoaErrorDomain 513).
- Fixed MTP device state recovery on USB disconnection or KalamError.deviceNotConnected.

## 1.6.2 - 2026-07-22

- Added filename-only search, separate extension filtering, and sort/group controls for name, size, type, and modified date.
- Added icon-view grouping by kind, extension, size range, and modified date while keeping folders navigable.
- Fixed status-bar size summaries to count direct files only and avoid recursive MTP folder scans that can spike CPU.
- Fixed MTP directory refresh behavior to avoid recursive root walks that can trigger invalid object handle errors on some Android devices.
- Fixed updater download progress so downloads show determinate progress when possible and only become installable after the artifact is staged.
- Added opt-in Sentry crash/error reporting with path redaction, project validation, test reporting, and dSYM upload support in release packaging.
- Fixed GitHub API update checks by adding the required User-Agent header to UpdaterService requests.
- Added reusable screenshot demo mode and replaced old manual screenshots with generated mock screenshots.
- Added a static Vercel-ready website that mirrors the README without overstating current features.

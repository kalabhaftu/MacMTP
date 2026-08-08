# Changelog

## Unreleased
- Next release.

## 1.6.8 - 2026-08-08

### MTP reliability
- Vendored the Kalam native adapter and its pinned Go dependency tree into macMTP, including license metadata and native contract checks. Builds and CI are now self-contained.
- Preserved the upstream MTP contracts across the native bridge: empty collections decode as `[]`, successful mutations require `data: true`, native `errorType` values are retained, and create/rename object IDs are available to Swift.
- Added a FIFO native-operation gate and a directory coordinator that serializes refresh, create, rename, and delete work, coalesces identical refreshes, rejects stale results, and keys snapshots by storage, path, and hidden-file visibility.
- Fixed empty-directory loading and refresh failure handling so a failed listing cannot masquerade as a different folder or a false empty directory.
- Made create, rename, and delete publish confirmed native results immediately. macMTP no longer sends an extra directory walk immediately after a mutation, avoiding Android devices that time out and close the USB session during that follow-up request.
- Added trimmed-name validation, listing-first duplicate detection, native fallback checks when a valid listing is unavailable, explicit duplicate conflict messages, and captured mutation destinations that are independent of selection.

### Finder-like file browser
- Replaced custom SwiftUI file-cell interaction with AppKit-backed collection and table views for native pointer-down selection, Command/Shift selection, blank-space deselection, keyboard focus, and double-click-only opening.
- Stabilized icon-grid geometry with fixed cells, reserved icon and label regions, fixed column sizing, two-line names, and selection backgrounds aligned to the cell bounds.
- Added Finder-style typeahead with repeated-letter cycling, multi-character queries, no-match recovery, exact single selection, modal/text-field suppression, and reset behavior after navigation, refresh, clicks, and dialogs.
- Centralized rename and New Folder dialogs with captured destination paths, reliable initial text, duplicate-submit protection, progress state, and dialog-preserving retry errors.
- Added visible organization headers with separator rules, group names, item counts, and explicit summaries for active grouping, sorting direction, and extension filters.

### Transfer and connection behavior
- Fixed transfer progress callback routing and frozen progress states, converted the upstream decimal MB/s callback to bytes per second without changing its units, and prevented invalid-storage transfers from starting.
- Made pause/resume operate at the file boundary: the current file finishes, then the queued transfer waits. Added visible pause feedback and transfer status notifications.
- Preserved clipboard state when a transfer request is rejected because another transfer is active, and routed native transfer failures to the correct completion callback.
- Reworked USB lifecycle handling around the active device identity with interface-settling debounce, immediate verified detach state, connection generations, cancellation of stale connection tasks, and reconnect reporting.

### Reporting, support, and release quality
- Expanded structured Sentry context for native operation, operation phase, error type, retry count, refresh coalescing, conflict classification, reconciliation state, USB events, reconnect results, and session generation while keeping paths and device identifiers redacted.
- Kept expected user/device conditions out of noisy error reports while preserving actionable native and transport failures for diagnosis.
- Added bug and feature issue templates, support-log guidance, native response fixtures, reliability tests, typeahead and grid tests, USB lifecycle tests, and release bundle validation.
- Hardened CI and release packaging with vendored native builds, shell/plist checks, architecture and signature verification, Sentry DSN/symbol validation, artifact checks, and changelog-driven release notes.

## 1.6.7 - 2026-07-29

- Filtered expected MTP device disconnects (`deviceNotConnected` and `no MTP devices found`) from Sentry error logging to eliminate false-positive production crash alerts.

## 1.6.6 - 2026-07-27

- Added ETag HTTP caching (`If-None-Match`), 6-hour background check throttling, and web HEAD redirect fallback to `UpdaterService` for GitHub API rate-limit resilience.
- Ensured updater alert prompts display clean, user-friendly version information and direct download links without technical jargon.

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

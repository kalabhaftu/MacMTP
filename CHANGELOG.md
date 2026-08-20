# Changelog

## Unreleased
- Next release.

## 1.6.9 - 2026-08-20

### Clipboard and transfer UX
- Added Finder-style file Copy and Paste through both keyboard shortcuts and the Edit menu, copying the exact selection from the active pane and pasting into the active pane's current directory.
- Added local-to-local, local-to-MTP, and MTP-to-local clipboard flows while keeping MTP-to-MTP explicitly unsupported and preserving clipboard contents when a request is rejected.
- Added native cancellation signaling through the vendored Kalam/go-mtpx progress callback so Cancel stops the active transfer at the next native USB chunk instead of waiting for the entire current file; native operations remain serialized until cancellation returns.
- Added clear cancellation and retry toasts for drag/drop and Paste attempts while native cancellation is finishing, and kept confirmed cancellation out of Sentry issues.
- Added concise copy confirmation toasts for files, folders, and multiple selected items.

### Search and file-browser behavior
- Fixed direct filename search so non-matching files and folders are both hidden, including a strict no-match result instead of leaving every folder visible.
- Made the search control focus its field immediately when opened and release focus when closed.
- Kept pane activation aligned with the last clicked file pane so Paste uses the intended destination, including clicks on empty pane space.
- Made AppKit browser updates idempotent and stopped redundant selection reloads, preserving native selection, blank-space deselection, keyboard focus, double-click opening, and stable icon-grid highlighting.

### USB detection and reporting
- Stopped auto-detection from selecting the first unrelated USB device; attach events now remain candidates until Kalam discovers an MTP-capable endpoint.
- Registered the active native device identity only after successful initialization, matching vendor, product, and serial data when available so unrelated USB devices cannot suppress Android reconnects.
- Deduplicated attach and detach handling, invalidated stale reconnect work, and preserved the active connection across unrelated device changes.
- Restored immediate launch-time USB scanning, bounded reconnect attempts, and stale-connection cleanup for phones already attached before macMTP opens and for rapid replug sequences.
- Routed lifecycle information and expected no-device conditions to breadcrumbs while retaining actionable native transport failures as Sentry events with redacted context.

### Verification and maintenance
- Added regression coverage for strict search filtering, clipboard selection and routing, cancelled-transfer lifecycle, USB identity matching, Sentry severity filtering, AppKit reload stability, and file-cell layout.
- Verified the native response contract, Swift test suite, shell and plist checks, x86_64 release bundle architecture/signature, and release packaging prerequisites.
- Verified 60 Swift tests, vendored Go compilation, native cancellation exports, and cancellation classification coverage.

### Updater hotfix
- Fixed the API-rate-limit fallback to download the published universal DMG asset and report the HTTP status and redacted URL when an update download fails.

### Crash hotfix
- Removed the custom AppKit host-view coordinate-system override that could trigger a Swift concurrency executor crash during collection-view drag sessions.

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

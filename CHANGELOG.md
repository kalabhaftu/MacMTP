# Changelog

## Unreleased

- Nothing yet.

## 1.6.2 - 2026-07-22

- Added filename-only search, separate extension filtering, and sort/group controls for name, size, type, and modified date.
- Added icon-view grouping by kind, extension, size range, and modified date while keeping folders navigable.
- Fixed status-bar size summaries to count direct files only and avoid recursive MTP folder scans that can spike CPU.
- Fixed MTP directory refresh behavior to avoid recursive root walks that can trigger invalid object handle errors on some Android devices.
- Fixed updater download progress so downloads show determinate progress when possible and only become installable after the artifact is staged.
- Added opt-in Sentry crash/error reporting with path redaction, project validation, test reporting, and dSYM upload support in release packaging.
- Added reusable screenshot demo mode and replaced old manual screenshots with generated mock screenshots.
- Added a static Vercel-ready website that mirrors the README without overstating current features.

# Repository Rules

- Read the relevant docs, source, tests, and recent history before changing behavior. Trace the failing path and identify the cause before editing.
- Keep fixes focused. Preserve existing features and contracts; avoid unrelated refactors and dependencies.
- Add focused regression coverage for changed behavior and run the checks available for the change. Do not claim macOS or device validation from Windows; use the macOS release workflow for release checks.
- Treat `.env`, `.env.sentry`, and other credentials as secrets. Use them locally; never print, commit, or copy their values into logs or artifacts.
- Sign every commit with a GitHub-verifiable key, using GitHub's signed commit flow or a registered local signing key. Before publishing, verify GitHub marks the release commit as verified.
- For releases, update the app version, build number, release script, and changelog together. Follow the repository release workflow and confirm its macOS checks pass and the expected assets are published.
- When changing Sentry issue state, verify the issue identity first, make the requested update, then read back and confirm its status.

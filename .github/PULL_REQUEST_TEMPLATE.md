## Summary

<!-- What user-visible behavior or maintenance gap does this change address? -->

## Verification

- [ ] `bash -n scripts/*.sh`
- [ ] `swift test`
- [ ] `bash scripts/build.sh release --arch "$(uname -m)"`
- [ ] `scripts/verify-app.sh macMTP.app "$(uname -m)"`

## Review notes

- [ ] Native-library behavior follows the upstream API contract; no duplicate engine logic was added.
- [ ] User-visible behavior is documented and `CHANGELOG.md` is updated when appropriate.
- [ ] Logs, paths, and credentials are not exposed in screenshots or diagnostics.

# Kalam Vendor Licenses

This directory contains the macMTP-owned Kalam adapter and the Go modules
required to build it. The pinned versions are recorded in
`native/vendor/modules.txt` and `MAINTENANCE.md`.

The adapter is distributed under the MIT terms that apply to its source. Dependency
license texts are kept beside their vendored sources:

| Module | License record |
| --- | --- |
| `github.com/ganeshrvel/go-mtpfs` | `native/vendor/github.com/ganeshrvel/go-mtpfs/LICENSE` |
| `github.com/ganeshrvel/go-mtpx` | No license file was present in the pinned source tree; the pinned version is recorded in `MAINTENANCE.md`. |
| `github.com/ganeshrvel/usb` | `native/vendor/github.com/ganeshrvel/usb/LICENSE` |
| `github.com/json-iterator/go` | `native/vendor/github.com/json-iterator/go/LICENSE` |
| `github.com/modern-go/concurrent` | `native/vendor/github.com/modern-go/concurrent/LICENSE` |
| `github.com/modern-go/reflect2` | `native/vendor/github.com/modern-go/reflect2/LICENSE` |

Do not replace or remove these records when refreshing the vendor tree.

# Contributing to macMTP

## Development Environment

- macOS 14.0+ (Sonoma)
- Swift 6.0+ (`xcode-select --install`)
- Go 1.21+ (`brew install go`)
- libusb (`brew install libusb`)

## Build & Run

```bash
git clone https://github.com/kalabhaftu/MacMTP.git
cd MacMTP

# Build
swift build

# Run
open .build/debug/macMTP.app
```

## Code Style

- Follow existing patterns in the codebase.
- Mimic surrounding code for imports, naming, and formatting.
- No unnecessary comments.
- Use SwiftUI idioms — prefer `@State`, `@Binding`, `@Observable` over manual delegates.

## Pull Request Process

1. Fork the repo and create a feature branch (`feature/my-change`).
2. Make your changes.
3. Run `swift build` — it must compile without errors or warnings.
4. Open a PR against `main`.
5. A maintainer will review within 7 days.
6. Address review feedback if requested.
7. Once approved and CI passes, a maintainer will merge.

## What to Work On

Check the issue tracker for:

- [`good first issue`](https://github.com/kalabhaftu/MacMTP/labels/good%20first%20issue)
- [`help wanted`](https://github.com/kalabhaftu/MacMTP/labels/help%20wanted)
- [`bug`](https://github.com/kalabhaftu/MacMTP/labels/bug)

Popular contribution areas: MTP device testing, UI polish, keyboard shortcuts, localization, tests.

## Reporting Issues

Include:

- macOS version
- Android device model and OS version
- macMTP version
- Steps to reproduce
- Logs from Console.app if applicable

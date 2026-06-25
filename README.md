# macMTP — Native macOS Android File Transfer

<p align="center">
  <strong>A modern, high-performance, native macOS utility for transferring files between Mac and Android devices via USB (MTP).</strong>
</p>

<p align="center">
  Built from scratch in <strong>Swift</strong> and <strong>SwiftUI</strong>. Powered by the battle-tested <strong>Kalam MTP Engine</strong> (Go).
</p>

<p align="center">
  <a href="https://github.com/kalabhaftu/MacMTP/actions/workflows/swift.yml">
    <img src="https://github.com/kalabhaftu/MacMTP/actions/workflows/swift.yml/badge.svg" alt="CI">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License">
  </a>
  <a href="https://github.com/kalabhaftu/MacMTP/releases">
    <img src="https://img.shields.io/github/v/release/kalabhaftu/MacMTP" alt="Release">
  </a>
  <a href="https://swift.org">
    <img src="https://img.shields.io/badge/Swift-6.0+-F05138.svg" alt="Swift">
  </a>
  <a href="https://go.dev">
    <img src="https://img.shields.io/badge/Go-1.21+-00ADD8.svg" alt="Go">
  </a>
</p>

---

## Why macMTP?

Transferring files between macOS and Android has always been painful. Google's official "Android File Transfer" app is abandoned and buggy. Most alternatives are either Electron-based (heavy on resources) or use WiFi/ADB (extremely slow). macMTP solves these problems:

| Problem | macMTP Solution |
|---------|----------------|
| Electron-based apps use 300+ MB RAM | Native Swift app uses ~30 MB RAM |
| 4GB file size limit in official app | No file size limits — transfer 50GB+ files |
| Frequent USB disconnections | Robust Kalam MTP engine with auto-reconnection |
| No conflict resolution on copy | SuperCopier-style conflict dialog with 5 options |
| Can't resume interrupted transfers | Skip-if-same-size detects completed files |
| Basic file browser UI | Finder-like sidebar with volumes, drives, bookmarks |
| No keyboard navigation | Letter-selection cycling, full keyboard shortcuts |
| No drag and drop | Native drag-and-drop between panes and Finder |
| No file type filtering | Filter by extension (.mp4, .jpg, etc.) |

---

## Features

### Core File Transfer

- **Plug and Play**: Connect your Android device via USB cable. macMTP auto-detects it instantly.
- **No File Size Limits**: Transfer files of any size — 4GB, 10GB, 50GB+.
- **Internal Storage & SD Card**: Choose between internal memory and SD card on your device.
- **Batch Transfers**: Copy hundreds of files at once with queue-based processing.
- **Transfer Speed**: 30-40 MB/s on budget devices, 100-120 MB/s on flagship devices.

### SuperCopier Conflict Resolution

When pasting files that already exist at the destination, macMTP gives you full control:

| Option | Behavior |
|--------|----------|
| **Overwrite All** | Replace all conflicting files unconditionally |
| **Skip All** | Skip every file that already exists at the destination |
| **Overwrite if Different** | Only replace files where the source and destination sizes differ |
| **Skip if Same Size (Resume)** | Keep fully-copied files, re-copy files that were partially transferred |
| **Cancel** | Abort the entire operation |

This means if you were copying 10 episodes and got interrupted at episode 5, you can resume — macMTP will skip the 5 completed episodes and continue from where it stopped.

### Finder-Like Interface

- **Native Sidebar**: Shows Macintosh HD, Home, Desktop, Downloads, Documents, Movies, Music, Pictures, and all mounted external drives/USB disks/DMGs — just like Finder.
- **Dual-Pane Layout**: Local filesystem on the left, Android device on the right.
- **Column Sorting**: Click column headers to sort by Name, Size, Type, or Date Modified.
- **File Type Filtering**: Type `.mp4` in the filter bar to show only MP4 files.
- **Dark Mode**: Full support for macOS dark mode with native system colors.

### Keyboard Navigation

| Shortcut | Action |
|----------|--------|
| Letter key | Jump to first file starting with that letter |
| Letter key (repeat) | Cycle through files starting with that letter |
| `⌘C` | Copy selected files |
| `⌘X` | Cut selected files |
| `⌘V` | Paste files |
| `⌘⌫` | Delete selected files |
| `⌘N` | Create new folder |
| `⌘R` | Refresh directory listing |
| `⌘A` | Select all files |
| `Enter` | Open / navigate into folder |
| `⌘↑` | Navigate to parent folder |
| `Shift+Click` | Range selection |
| `⌘+Click` | Toggle individual selection |

### Drag and Drop

- Drag files from the local pane to the MTP pane (upload).
- Drag files from the MTP pane to the local pane (download).
- Drag files from Finder into macMTP (upload to device).
- Drag files from macMTP to Finder (download from device).

---

## System Requirements

- **macOS**: 14.0 (Sonoma) or later
- **Architecture**: Intel (x86_64) and Apple Silicon (arm64)
- **USB**: Standard USB cable connecting Mac to Android device
- **Android**: USB debugging or MTP file transfer mode enabled

---

## Installation

### Download Pre-built Binary

Download the latest release from the [Releases](https://github.com/kalabhaftu/MacMTP/releases) page:

- **DMG Installer**: `MacMTP-X.Y.Z-mac-x86_64.dmg` — Open and drag to Applications
- **ZIP Archive**: `MacMTP-X.Y.Z-mac-x86_64.zip` — Unzip and move to Applications

### Build from Source

#### Prerequisites

- macOS 14.0+
- Swift 6.0+ (via Xcode Command Line Tools: `xcode-select --install`)
- Go 1.21+ (`brew install go`)
- libusb (`brew install libusb`)

#### Clone and Build

```bash
git clone https://github.com/kalabhaftu/MacMTP.git
cd MacMTP

# Quick build (debug mode)
swift build

# Release build
swift build -c release

# Run the app
open .build/debug/macMTP.app
```

#### Release Packaging

To create DMG and ZIP distribution packages:

```bash
./scripts/release.sh 1.0.0
```

This generates:

```
release/
├── MacMTP-1.0.0-mac-x86_64.dmg      # DMG installer with Applications shortcut
├── MacMTP-1.0.0-mac-x86_64.dmg.sha256
├── MacMTP-1.0.0-mac-x86_64.zip      # ZIP archive
├── MacMTP-1.0.0-mac-x86_64.zip.sha256
└── latest-mac.yml                    # Release manifest
```

---

## Architecture

macMTP is built on a clean layered architecture:

```
┌──────────────────────────────────────────┐
│          SwiftUI Frontend               │
│  (ContentView, FileExplorerPane, etc.)  │
├──────────────────────────────────────────┤
│        Swift Service Layer              │
│  (ClipboardManager, FileTransfer,       │
│   ConflictResolver, USBWatcher)         │
├──────────────────────────────────────────┤
│        KalamBridge (Swift↔C FFI)        │
│  (Async wrappers, JSON parsing)         │
├──────────────────────────────────────────┤
│        Go Kalam MTP Engine              │
│  (Static C-archive: libkalam.a)         │
│  (go-mtpx, go-mtpfs libraries)          │
├──────────────────────────────────────────┤
│        libusb (USB transport)           │
│  (User-space USB communication)         │
└──────────────────────────────────────────┘
```

### Why Go for the MTP Engine?

The Kalam MTP engine is written in Go because:

1. **Battle-tested**: Used by OpenMTP with thousands of users across hundreds of Android device models.
2. **Edge-case handling**: Years of fixes for Samsung, Pixel, OnePlus, Xiaomi, and other manufacturer-specific MTP quirks.
3. **Performance**: Go's concurrency model enables efficient bulk file transfers.
4. **Stability**: The `go-mtpx` library handles USB timeouts, EOF errors, and storage access issues gracefully.

We compile it as a static C-archive (`libkalam.a`) and bridge it into Swift via C function pointers.

---

## Project Structure

```
macmtp/
├── Package.swift                  # Swift Package Manager configuration
├── README.md                      # This document
├── .gitignore
├── Sources/
│   ├── CKalam/                    # C bridge target for Go library
│   │   ├── include/
│   │   │   ├── kalam.h            # Go-generated C header
│   │   │   └── module.modulemap   # Swift module map
│   │   ├── shim.c                 # Required by SPM
│   │   └── libkalam.a             # Go static library (compiled)
│   └── macmtp/                    # Main Swift application
│       ├── App/
│       │   └── main.swift         # App entry point, window, menu bar
│       ├── Views/
│       │   ├── ContentView.swift  # Main split-pane layout
│       │   ├── FileExplorerPane.swift  # File table with sorting, filtering
│       │   ├── SidebarView.swift  # Finder-like sidebar with volumes
│       │   ├── ToolbarView.swift  # Operation toolbar
│       │   ├── StatusView.swift   # Bottom status bar
│       │   ├── ConflictDialogView.swift  # SuperCopier conflict sheet
│       │   └── TransferProgressView.swift  # Transfer progress panel
│       ├── Models/
│       │   ├── FileNode.swift     # File/directory data model
│       │   ├── DeviceInfo.swift   # MTP device & storage models
│       │   ├── TransferItem.swift # Transfer queue models
│       │   └── ClipboardManager.swift  # App clipboard
│       ├── MTP/
│       │   ├── KalamBridge.swift  # Swift↔C FFI bridge
│       │   └── MTPDeviceManager.swift  # Device state manager
│       ├── Services/
│       │   ├── FileTransferService.swift  # Transfer queue engine
│       │   └── USBWatcher.swift   # IOKit USB monitoring
│       └── Utilities/
│           └── FormatUtils.swift  # Formatting helpers
├── Resources/
│   └── Info.plist
├── scripts/
│   ├── build.sh                   # Build script
│   └── release.sh                 # Release packaging script
└── release/                       # Generated release artifacts
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide — setup, code style, PR process, and areas to work on.

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Report security issues via [SECURITY.md](SECURITY.md).

Governance and decision-making are documented in [GOVERNANCE.md](GOVERNANCE.md).

---

## Acknowledgments

- **[Kalam MTP Engine](https://github.com/ganeshrvel/go-mtpx)** — The Go-based MTP kernel by Ganesh Rathinavel
- **[OpenMTP](https://github.com/ganeshrvel/openmtp)** — The original Electron-based Android file transfer app that inspired this project
- **[libusb](https://libusb.info/)** — Cross-platform USB library

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <em>Made with ❤️ for the macOS and Android community</em>
</p>

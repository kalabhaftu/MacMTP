// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let env = ProcessInfo.processInfo.environment
let hostArch = env["HOSTTYPE"] ?? env["RUNNER_ARCH"] ?? env["NATIVE_ARCH"] ?? ""
let libusbLibDir = env["MACMTP_LIBUSB_LIB_DIR"]
let defaultLibusbSearchPaths = hostArch.contains("arm64")
    || hostArch == "ARM64"
    ? ["/opt/homebrew/lib", "/usr/local/lib"]
    : ["/usr/local/lib", "/opt/homebrew/lib"]
let existingDefaultLibusbSearchPaths = defaultLibusbSearchPaths.filter {
    FileManager.default.fileExists(atPath: $0)
}
let selectedLibusbSearchPaths = libusbLibDir.map { [$0] }
    ?? (existingDefaultLibusbSearchPaths.isEmpty ? defaultLibusbSearchPaths : existingDefaultLibusbSearchPaths)
let libusbLinkerFlags = selectedLibusbSearchPaths
    .flatMap { ["-L\($0)"] } + ["-lusb-1.0"]
let kalamLinkerFlags = [
    "-L\(packageDir)/Sources/CKalam",
    "-lkalam",
]

let package = Package(
    name: "macmtp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.19.0")
    ],
    targets: [
        // C target that exposes the Go Kalam static library headers
        .target(
            name: "CKalam",
            path: "Sources/CKalam",
            sources: ["shim.c", "early_init.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .unsafeFlags(kalamLinkerFlags),
                .unsafeFlags(libusbLinkerFlags),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),

        // Main macOS application target
        .executableTarget(
            name: "macmtp",
            dependencies: [
                "CKalam",
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: "Sources/macmtp",

            linkerSettings: [
                .unsafeFlags(kalamLinkerFlags + libusbLinkerFlags),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)

// swift-tools-version: 6.1

import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

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
                .unsafeFlags([
                    "-L\(packageDir)/Sources/CKalam",
                    "-lkalam",
                ]),
                .unsafeFlags([
                    "-L/usr/local/lib",
                    "-L/opt/homebrew/lib",
                    "-lusb-1.0",
                ]),
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
                .unsafeFlags([
                    "-L\(packageDir)/Sources/CKalam",
                    "-lkalam",
                    "-L/usr/local/lib",
                    "-L/opt/homebrew/lib",
                    "-lusb-1.0",
                ]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)

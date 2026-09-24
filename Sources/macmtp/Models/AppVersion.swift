import Foundation

public struct AppVersion {
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ProcessInfo.processInfo.environment["MACMTP_VERSION"]
            ?? "development"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development"
    }

    public static var sourceRevision: String {
        Bundle.main.object(forInfoDictionaryKey: "SourceRevision") as? String
            ?? ProcessInfo.processInfo.environment["MACMTP_SOURCE_REVISION"]
            ?? "development"
    }

    public static var sentryRelease: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.macmtp.app"
        return "\(bundleIdentifier)@\(current)+\(build)"
    }
}

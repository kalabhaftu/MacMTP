import Foundation
import OSLog
import Sentry

public enum ErrorReportingStatus: Equatable {
    case disabled
    case invalidConfiguration
    case unavailable
    case ready
}

public enum TestReportResult: Equatable, Sendable {
    case accepted
    case rejected(statusCode: Int)
    case unavailable

    var message: String {
        switch self {
        case .accepted:
            "Test report accepted by Sentry."
        case .rejected(let statusCode):
            "Sentry rejected the test report (HTTP \(statusCode))."
        case .unavailable:
            "Test report could not reach Sentry."
        }
    }
}

public struct ErrorLogger {
    private static let lifecycleLock = NSLock()
    private static let systemLogger = Logger(subsystem: "com.macmtp.app", category: "errors")

    private static var dsn: String {
        ProcessInfo.processInfo.environment["SENTRY_DSN"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String
            ?? ""
    }

    public static var status: ErrorReportingStatus {
        guard reportsEnabled else { return .disabled }
        guard isValidDSN(dsn) else { return .invalidConfiguration }
        return SentrySDK.isEnabled ? .ready : .unavailable
    }

    public static func startIfEnabled() {
        _ = ensureStarted()
    }

    public static func setReportingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "sendCrashReports")

        if enabled {
            _ = ensureStarted()
        } else if SentrySDK.isEnabled {
            SentrySDK.close()
        }
    }

    public static func log(_ error: Error, message: String? = nil, userInfo: [String: Any]? = nil) {
        let originalError = error as NSError
        let reportDescription = [message, error.localizedDescription]
            .compactMap { $0 }
            .map(sanitize)
            .joined(separator: ": ")
        systemLogger.error("\(reportDescription, privacy: .private)")

        guard ensureStarted() else { return }
        guard shouldReport(error) else { return }

        let reportError = NSError(
            domain: originalError.domain,
            code: originalError.code,
            userInfo: [NSLocalizedDescriptionKey: reportDescription]
        )

        SentrySDK.capture(error: reportError) { scope in
            scope.setTag(value: String(describing: type(of: error)), key: "error_type")
            scope.setTag(value: originalError.domain, key: "error_domain")
            if let kalamError = error as? KalamError {
                scope.setTag(value: kalamError.reportingCase, key: "kalam_error_case")
                if case .nativeOperationFailed(let operation, let errorType, _) = kalamError {
                    scope.setTag(value: operation, key: "mtp_operation")
                    if let errorType, !errorType.isEmpty {
                        scope.setTag(value: errorType, key: "native_error_type")
                    }
                }
            }
            sanitizedExtras(userInfo).forEach { key, value in
                scope.setExtra(value: value, key: key)
            }
        }
    }

    public static func logMessage(_ message: String, level: SentryLevel = .error, userInfo: [String: Any]? = nil) {
        systemLogger.log(level: level == .warning ? .default : .error, "\(sanitize(message), privacy: .private)")
        guard ensureStarted() else { return }

        let event = Event(level: level)
        event.message = SentryMessage(formatted: sanitize(message))
        event.extra = sanitizedExtras(userInfo)
        SentrySDK.capture(event: event)
    }

    public static func captureTestReport() async -> TestReportResult {
        guard reportsEnabled,
              let configuration = storeConfiguration(for: dsn) else {
            return .unavailable
        }

        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let payload: [String: Any] = [
            "event_id": eventID,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "platform": "cocoa",
            "level": "info",
            "logger": "macmtp.diagnostic",
            "message": "User-requested macMTP error-reporting test",
            "release": AppVersion.sentryRelease,
            "environment": "production",
            "tags": ["diagnostic": "reporting_test"],
        ]

        do {
            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Sentry sentry_version=7, sentry_client=macmtp/\(AppVersion.current), sentry_key=\(configuration.publicKey)",
                forHTTPHeaderField: "X-Sentry-Auth"
            )
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unavailable
            }
            return (200..<300).contains(httpResponse.statusCode)
                ? .accepted
                : .rejected(statusCode: httpResponse.statusCode)
        } catch {
            return .unavailable
        }
    }

    static func isValidDSN(_ value: String) -> Bool {
        storeConfiguration(for: value) != nil
    }

    static func sanitize(_ value: String) -> String {
        let replacements = [
            #"(?i)file://\S+"#,
            #"/Users/[^/\s]+(?:/[^\s,:;)]*)?"#,
            #"/Volumes/[^/\s]+(?:/[^\s,:;)]*)?"#,
            #"/private/var/folders/\S+"#,
        ]

        return replacements.reduce(value) { result, pattern in
            result.replacingOccurrences(
                of: pattern,
                with: "<redacted-path>",
                options: .regularExpression
            )
        }
    }

    static func shouldReport(_ error: Error) -> Bool {
        guard let kalamError = error as? KalamError else { return true }

        switch kalamError {
        case .deviceNotConnected:
            return false
        case .operationFailed(let message)
            where message.localizedCaseInsensitiveContains("no MTP devices found"):
            return false
        case .nativeOperationFailed(_, let errorType, let message):
            let normalized = "\(errorType ?? "") \(message)".lowercased()
            return !normalized.contains("no mtp devices found")
                && !normalized.contains("errormtpdetectfailed")
        default:
            return true
        }
    }

    static func withAppHangTrackingPaused<T>(_ operation: () throws -> T) rethrows -> T {
        guard SentrySDK.isEnabled else { return try operation() }

        SentrySDK.pauseAppHangTracking()
        defer { SentrySDK.resumeAppHangTracking() }
        return try operation()
    }

    private static func ensureStarted() -> Bool {
        guard reportsEnabled, isValidDSN(dsn) else { return false }

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if !SentrySDK.isEnabled {
            SentrySDK.start { options in
                options.dsn = dsn
                options.debug = false
                options.sendDefaultPii = false
                options.releaseName = AppVersion.sentryRelease
                options.environment = "production"
                options.appHangTimeoutInterval = 5.0
            }
        }
        return SentrySDK.isEnabled
    }

    private static func sanitizedExtras(_ extras: [String: Any]?) -> [String: Any] {
        guard let extras else { return [:] }
        return extras.reduce(into: [:]) { result, entry in
            if let string = entry.value as? String {
                result[entry.key] = sanitize(string)
            } else if entry.value is Bool || entry.value is Int || entry.value is Int64 || entry.value is Double {
                result[entry.key] = entry.value
            }
        }
    }

    private static func storeConfiguration(for value: String) -> (endpoint: URL, publicKey: String)? {
        guard var components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.isEmpty == false,
              let publicKey = components.user,
              !publicKey.isEmpty else {
            return nil
        }

        let pathComponents = components.path.split(separator: "/").map(String.init)
        guard let projectID = pathComponents.last,
              !projectID.isEmpty,
              projectID.allSatisfy(\.isNumber) else {
            return nil
        }

        let pathPrefix = pathComponents.dropLast()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/" + (pathPrefix + ["api", projectID, "store"]).joined(separator: "/") + "/"

        guard let endpoint = components.url else { return nil }
        return (endpoint, publicKey)
    }

    private static var reportsEnabled: Bool {
        UserDefaults.standard.object(forKey: "sendCrashReports") as? Bool ?? true
    }
}

private extension KalamError {
    var reportingCase: String {
        switch self {
        case .deviceNotConnected: "device_not_connected"
        case .transferFailed: "transfer_failed"
        case .operationFailed: "operation_failed"
        case .nativeOperationFailed: "native_operation_failed"
        case .invalidResponse: "invalid_response"
        case .serializationError: "serialization_error"
        case .operationInProgress: "operation_in_progress"
        case .timedOut: "timed_out"
        case .invalidPath: "invalid_path"
        }
    }
}

import Foundation
import Sentry

public struct ErrorLogger {
    public static func startIfEnabled() {
        guard reportsEnabled else { return }
        SentrySDK.start { options in
            options.dsn = "https://85a2a845bf5e0409b28e64c446f870e1@o4511628143820800.ingest.us.sentry.io/4511628158763008"
            options.debug = false
            options.sendDefaultPii = false
            options.releaseName = AppVersion.current
        }
    }

    public static func log(_ error: Error, message: String? = nil, userInfo: [String: Any]? = nil) {
        guard reportsEnabled else { return }

        let errorMessage = message.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: errorMessage)
        var tags = [
            "error_type": String(describing: type(of: error)),
            "error_domain": (error as NSError).domain,
        ]
        if let kalamErr = error as? KalamError {
            tags["kalam_error_case"] = String(describing: kalamErr)
        }
        event.tags = tags
        event.extra = userInfo ?? [:]
        SentrySDK.capture(event: event)
    }
    
    public static func logMessage(_ message: String, level: SentryLevel = .error, userInfo: [String: Any]? = nil) {
        guard reportsEnabled else { return }
        let event = Event(level: level)
        event.message = SentryMessage(formatted: message)
        event.extra = userInfo ?? [:]
        SentrySDK.capture(event: event)
    }

    private static var reportsEnabled: Bool {
        // Consent is opt-in. Do not send errors before the first-run prompt is answered.
        UserDefaults.standard.object(forKey: "sendCrashReports") as? Bool ?? false
    }
}

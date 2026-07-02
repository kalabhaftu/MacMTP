import Foundation
import Sentry

public struct ErrorLogger {
    public static func log(_ error: Error, message: String? = nil, userInfo: [String: Any]? = nil) {
        let errMsg = message != nil ? "\(message!): \(error.localizedDescription)" : error.localizedDescription
        print("[ERROR] \(errMsg)")
        
        let sendReports = UserDefaults.standard.object(forKey: "sendCrashReports") as? Bool ?? true
        if sendReports {
            let event = Event(level: .error)
            event.message = SentryMessage(formatted: errMsg)
            
            var tags = [String: String]()
            tags["error_type"] = String(describing: type(of: error))
            if let kalamErr = error as? KalamError {
                tags["kalam_error_case"] = String(describing: kalamErr)
            }
            event.tags = tags
            
            if let userInfo = userInfo {
                event.extra = userInfo
            }
            
            SentrySDK.capture(event: event)
        }
    }
    
    public static func logMessage(_ message: String, level: SentryLevel = .error, userInfo: [String: Any]? = nil) {
        print("[\(level == .info ? "INFO" : "ERROR")] \(message)")
        
        let sendReports = UserDefaults.standard.object(forKey: "sendCrashReports") as? Bool ?? true
        if sendReports {
            let event = Event(level: level)
            event.message = SentryMessage(formatted: message)
            if let userInfo = userInfo {
                event.extra = userInfo
            }
            SentrySDK.capture(event: event)
        }
    }
}

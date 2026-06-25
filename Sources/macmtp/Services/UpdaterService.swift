import Foundation
import AppKit

@MainActor
public final class UpdaterService: ObservableObject, @unchecked Sendable {
    public static let shared = UpdaterService()
    
    private let repoURL = "https://api.github.com/repos/macmtp/macmtp/releases/latest"
    
    private init() {}
    
    public func checkForUpdates(silent: Bool = false) {
        Task {
            do {
                guard let url = URL(string: repoURL) else { return }
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10
                
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    if !silent { showNoUpdateAlert(message: "Failed to fetch update information from GitHub.") }
                    return
                }
                
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String,
                   let htmlUrlString = json["html_url"] as? String,
                   let htmlUrl = URL(string: htmlUrlString) {
                    
                    let releaseBody = (json["body"] as? String) ?? "No release notes available."
                    
                    let remoteVersion = tagName.replacingOccurrences(of: "v", with: "")
                    let localVersion = AppVersion.current.replacingOccurrences(of: "v", with: "")
                    
                    if remoteVersion.compare(localVersion, options: .numeric) == .orderedDescending {
                        showUpdateAlert(version: tagName, releaseNotes: releaseBody, url: htmlUrl)
                    } else {
                        if !silent { showNoUpdateAlert(message: "You are running the latest version of macMTP (\(AppVersion.current)).") }
                    }
                } else {
                    if !silent { showNoUpdateAlert(message: "Failed to parse update information.") }
                }
            } catch {
                if !silent { showNoUpdateAlert(message: "Error checking for updates: \(error.localizedDescription)") }
            }
        }
    }
    
    private func showUpdateAlert(version: String, releaseNotes: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "A new version of macMTP is available!"
        alert.informativeText = "Version \(version) is now available. You are running version \(AppVersion.current).\n\nRelease Notes:\n\(releaseNotes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        
        // Limit the width of the informative text to avoid giant alerts
        let accessory = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        accessory.string = releaseNotes
        accessory.isEditable = false
        accessory.drawsBackground = false
        accessory.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        
        // Use scroll view
        let scroll = NSScrollView(frame: accessory.frame)
        scroll.documentView = accessory
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        
        // Clear informative text since we are using accessory view for notes
        alert.informativeText = "Version \(version) is now available. You are running version \(AppVersion.current)."
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func showNoUpdateAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Check for Updates"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

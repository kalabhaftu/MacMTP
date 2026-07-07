import Cocoa
import SwiftUI
import Sentry


class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var preferencesWindowController: NSWindowController?
    var aboutWindowController: NSWindowController?
    var helpWindowController: NSWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "macMTP"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.setFrameAutosaveName("macMTPMainWindow")
        window.minSize = NSSize(width: 900, height: 550)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        
        setupMainMenu()
        
        let sendReports = UserDefaults.standard.object(forKey: "sendCrashReports") as? Bool ?? true
        if sendReports {
            SentrySDK.start { options in
                options.dsn = "https://85a2a845bf5e0409b28e64c446f870e1@o4511628143820800.ingest.us.sentry.io/4511628158763008"
                options.debug = false
                options.sendDefaultPii = true
                options.releaseName = AppVersion.current
                
                options.tracesSampleRate = 1.0
                
            }
        }
        
        USBWatcher.shared.startWatching()
        
        Task {
            let autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
            if autoCheck {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                UpdaterService.shared.checkForUpdates(silent: true)
            }
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }
    
    
    @MainActor private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About macMTP", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide macMTP", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit macMTP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Folder", action: #selector(menuNewFolder), keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "macMTP Help", action: #selector(showHelp), keyEquivalent: "?")
        helpMenu.addItem(withTitle: "Report an Issue…", action: #selector(openIssueTracker), keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    
    @MainActor @objc private func showAbout() {
        if let existing = aboutWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: AboutView())
        let aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        aboutWindow.titlebarAppearsTransparent = true
        aboutWindow.titleVisibility = .hidden
        aboutWindow.isMovableByWindowBackground = true
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.contentView = hostingView
        aboutWindow.center()
        
        let controller = NSWindowController(window: aboutWindow)
        aboutWindowController = controller
        aboutWindow.makeKeyAndOrderFront(nil)
    }
    
    @MainActor @objc private func checkForUpdates() {
        UpdaterService.shared.checkForUpdates(silent: false)
    }
    
    @objc private func menuNewFolder() {
        NotificationCenter.default.post(name: .menuNewFolderRequested, object: nil)
    }

    @objc private func menuRefresh() {
        NotificationCenter.default.post(name: .menuRefreshRequested, object: nil)
    }

    @objc private func openIssueTracker() {
        if let url = URL(string: "https://github.com/kalabhaftu/MacMTP/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor @objc private func showPreferences() {
        if let existing = preferencesWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: PreferencesView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macMTP Preferences"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        let controller = NSWindowController(window: window)
        preferencesWindowController = controller
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc private func showHelp() {
        if let existing = helpWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: HelpView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macMTP Help"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        let controller = NSWindowController(window: window)
        helpWindowController = controller
        window.makeKeyAndOrderFront(nil)
    }
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

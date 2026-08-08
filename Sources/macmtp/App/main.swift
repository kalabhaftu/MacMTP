import Cocoa
import SwiftUI


class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var preferencesWindowController: NSWindowController?
    var aboutWindowController: NSWindowController?
    var helpWindowController: NSWindowController?
    private var terminationPromptInFlight = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        ErrorLogger.startIfEnabled()

        let contentView = ContentView(screenshotMode: ScreenshotDemo.isEnabled)
        
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
        if ScreenshotDemo.isEnabled {
            window.setFrame(NSRect(x: 120, y: 120, width: 1200, height: 760), display: false)
        } else {
            window.setFrameAutosaveName("macMTPMainWindow")
        }
        window.minSize = NSSize(width: 900, height: 550)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        
        setupMainMenu()
        
        if !ScreenshotDemo.isEnabled {
            USBWatcher.shared.startWatching()
        }
        
        Task {
            guard !ScreenshotDemo.isEnabled else { return }
            let autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
            if autoCheck {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                UpdaterService.shared.checkForUpdates(silent: true)
            }
        }
        
        NSApp.activate(ignoringOtherApps: true)

        if ScreenshotDemo.isEnabled {
            showRequestedScreenshotPage()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        USBWatcher.shared.stopWatching()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let transferState = FileTransferService.shared.activeBatch?.state
        let transferActive = transferState == .transferring || transferState == .paused
        let mtpMutationActive = MTPDeviceManager.shared.isPerformingMutation

        guard transferActive || mtpMutationActive else { return .terminateNow }
        guard !terminationPromptInFlight else { return .terminateLater }

        terminationPromptInFlight = true
        defer { terminationPromptInFlight = false }

        let alert = NSAlert()
        alert.messageText = "Quit macMTP?"
        alert.informativeText = transferActive
            ? "A file transfer is still in progress. Quitting will interrupt it."
            : "An MTP operation is still in progress. Quitting may interrupt it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Working")

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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

    @MainActor private func showRequestedScreenshotPage() {
        switch ScreenshotDemo.requestedPage {
        case "preferences":
            showPreferences()
            window.orderOut(nil)
        case "help":
            showHelp()
            window.orderOut(nil)
        case "about":
            showAbout()
            window.orderOut(nil)
        case "transfer":
            showTransferDemo()
            window.orderOut(nil)
        case "conflict":
            showConflictDemo()
            window.orderOut(nil)
        default:
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor private func showTransferDemo() {
        let hostingView = NSHostingView(rootView: TransferProgressView(batch: ScreenshotDemo.transferBatch()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macMTP Transfer"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor private func showConflictDemo() {
        let resolution = Binding<ConflictResolution?>(
            get: { nil },
            set: { _ in }
        )
        let remember = Binding<Bool>(
            get: { true },
            set: { _ in }
        )
        let hostingView = NSHostingView(rootView: ConflictDialogView(
            conflictingFiles: ScreenshotDemo.conflicts,
            totalFileCount: 8,
            resolution: resolution,
            rememberForBatch: remember
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macMTP File Conflict"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
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

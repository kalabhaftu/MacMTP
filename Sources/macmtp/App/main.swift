import Cocoa
import SwiftUI
import Darwin

// MARK: - Application Delegate

/// creates the native menu bar, and handles application-level events
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var preferencesWindowController: NSWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the main SwiftUI content view
        let contentView = ContentView()
        
        // Configure the main window
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
        
        // Build the menu bar
        setupMainMenu()
        
        // Start USB device monitoring
        USBWatcher.shared.startWatching()
        
        // Start MTP device auto-connection
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s delay for USB to settle
            if !MTPDeviceManager.shared.isConnected {
                await MTPDeviceManager.shared.connectDevice()
            }
        }
        
        // Bring the app to the foreground
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup: dispose of any active MTP connections
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
    
    // MARK: - Menu Bar Setup
    
    @MainActor private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // ── Application Menu ──
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About macMTP", action: #selector(showAbout), keyEquivalent: "")
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
        
        // ── File Menu ──
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Folder", action: nil, keyEquivalent: "")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        
        // ── Edit Menu ──
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        // ── View Menu ──
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Refresh", action: nil, keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        
        // ── Window Menu ──
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        // ── Help Menu ──
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "macMTP Help", action: #selector(showHelp), keyEquivalent: "?")
        helpMenu.addItem(withTitle: "Report an Issue…", action: #selector(openIssueTracker), keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    // MARK: - Menu Actions
    
    @MainActor @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "macMTP"
        alert.informativeText = """
        Version 1.0.0
        
        A native macOS Android file transfer utility.
        Built with Swift and SwiftUI.
        
        Powered by the Kalam MTP Engine.
        
        © 2024 macMTP Contributors
        MIT License
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc private func openIssueTracker() {
        if let url = URL(string: "https://github.com/macmtp/macmtp/issues") {
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macMTP Preferences"
        window.contentView = hostingView
        window.center()
        let controller = NSWindowController(window: window)
        preferencesWindowController = controller
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc private func showHelp() {
        let hostingView = NSHostingView(rootView: HelpView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macMTP Help"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Application Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

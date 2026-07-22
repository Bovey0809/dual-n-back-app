import AppKit
import SwiftUI

// Pure-AppKit lifecycle so we keep full control over windows (needed for the
// kiosk lock). SwiftUI is hosted per-window via NSHostingController.
@main
enum DualNBackMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var game: GameEngine!
    private(set) var lockManager: LockManager!
    private let kiosk = KioskController()
    private var normalWindow: NSWindow?
    private var keyMonitor: Any?

    private let isAutostart = CommandLine.arguments.contains("--autostart")
    // --test-lock dailyMinutes=0.5,idleThresholdSeconds=10 → numeric config overrides (in-memory only)
    private let testOverrides = AppDelegate.parseTestOverrides(CommandLine.arguments)

    static func parseTestOverrides(_ argv: [String]) -> [String: Double]? {
        guard let i = argv.firstIndex(of: "--test-lock") else { return nil }
        var out: [String: Double] = [:]
        let next = i + 1
        if argv.indices.contains(next), !argv[next].hasPrefix("--") {
            for pair in argv[next].split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let v = Double(kv[1]) { out[String(kv[0])] = v }
            }
        }
        return out
    }

    // Lock semantics are active only when the agent is installed (feature switch)
    // or when explicitly testing. Evaluated live so toggling reacts immediately.
    var isLockEnabled: Bool {
        testOverrides != nil || LaunchAgentInstaller.isInstalled
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
        buildMainMenu()

        game = GameEngine()
        lockManager = LockManager(
            stateDir: FileLocations.appSupportDir,
            configOverrides: testOverrides,
            isLockEnabled: { [unowned self] in self.isLockEnabled },
            onUnlocked: { [unowned self] in self.showNormalWindow() },
            kiosk: kiosk
        )
        lockManager.game = game
        kiosk.makeContent = { [unowned self] in self.makeContentViewController(lockMode: true) }
        lockManager.initialize()

        installKeyMonitor()

        // Autostart stays silent unless the manager decided to lock;
        // a manual launch always shows a window.
        if !lockManager.isLocked && !isAutostart {
            showNormalWindow()
        }
    }

    // Single instance (parity with Electron requestSingleInstanceLock): the
    // LaunchAgent execs the binary directly, which bypasses LaunchServices'
    // own single-instance handling.
    private func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DualNBack",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DualNBack",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DualNBack",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu so typing/copy/paste works (e.g. the emergency-skip pledge).
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeContentViewController(lockMode: Bool) -> NSViewController {
        NSHostingController(
            rootView: ContentView(lockMode: lockMode)
                .environmentObject(game!)
                .environmentObject(lockManager!)
        )
    }

    func showNormalWindow() {
        if let w = normalWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "Dual N-Back Training"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 1200, height: 800)
        w.isReleasedWhenClosed = false
        w.contentViewController = makeContentViewController(lockMode: false)

        // 1600×1200 default, clamped to the visible screen area.
        var size = NSSize(width: 1600, height: 1200)
        if let visible = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
        }
        w.setContentSize(size)
        w.center()
        w.delegate = self
        normalWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === normalWindow {
            normalWindow = nil
        }
    }

    // Global A / L / Space shortcuts (parity with the renderer keydown handler).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            if event.isARepeat { return event }
            // Don't steal keys while typing (e.g. the skip pledge text field).
            if let responder = event.window?.firstResponder, responder is NSTextView { return event }
            if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return event }
            guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch chars {
            case "a":
                self.game.markInput()
                self.game.recordResponse(.visual)
                return nil
            case "l":
                self.game.markInput()
                self.game.recordResponse(.audio)
                return nil
            case " ":
                self.game.markInput()
                self.game.toggleGame()
                return nil
            default:
                return event
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let lockManager, !lockManager.isLocked {
            showNormalWindow()
        }
        return true
    }

    // Quit policy (spec §4.5 / §6):
    //   LOCKED            → never quit
    //   lock feature on   → stay resident (hide windows instead of quitting)
    //   DEGRADED or off   → normal quit allowed
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lockManager else { return .terminateNow }
        if lockManager.isLocked { return .terminateCancel }
        if lockManager.mode != .degraded && isLockEnabled {
            for w in NSApp.windows { w.orderOut(nil) }
            return .terminateCancel
        }
        lockManager.flushState()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

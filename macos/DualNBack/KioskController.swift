import AppKit

/// Lock-mode window management — port of src/main/kiosk.js.
/// One kiosk window on the primary display, a blackout window on every other
/// display, refreshed on hot-plug. Kiosk-grade presentation options replace
/// Electron's globalShortcut + empty-menu tricks.
final class KioskController {
    /// Supplied by AppDelegate: builds the lock-mode content view controller.
    var makeContent: (() -> NSViewController)?

    private(set) var kioskWindow: NSWindow?
    private var blackouts: [NSNumber: NSWindow] = [:]
    private(set) var isActive = false
    private var screenObserver: NSObjectProtocol?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private func pinToTop(_ window: NSWindow) {
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func create() {
        guard !isActive else { return }
        isActive = true

        savedPresentationOptions = NSApp.presentationOptions
        // Kiosk set: hides Dock/menu bar, blocks Cmd+Tab, Cmd+Q/H and logout.
        // (Force-quit via Cmd+Opt+Esc is disabled too, but as the README notes,
        // a determined user can always kill the process — launchd revives us.)
        NSApp.presentationOptions = [
            .hideDock, .hideMenuBar, .disableAppleMenu,
            .disableProcessSwitching, .disableForceQuit,
            .disableSessionTermination, .disableHideApplication,
        ]

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        pinToTop(window)
        if let makeContent {
            window.contentViewController = makeContent()
        }
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        kioskWindow = window

        syncBlackouts()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncBlackouts()
        }
    }

    func destroy() {
        guard isActive else { return }
        isActive = false

        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        NSApp.presentationOptions = savedPresentationOptions

        kioskWindow?.orderOut(nil)
        kioskWindow?.contentViewController = nil
        kioskWindow = nil

        for (_, window) in blackouts { window.orderOut(nil) }
        blackouts.removeAll()
    }

    // MARK: Blackouts

    private static func screenID(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func addBlackout(for screen: NSScreen, id: NSNumber) {
        guard blackouts[id] == nil else { return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.ignoresMouseEvents = false
        pinToTop(window)
        window.orderFrontRegardless()
        blackouts[id] = window
    }

    private func syncBlackouts() {
        guard isActive else { return }
        let primary = NSScreen.main ?? NSScreen.screens.first
        let primaryID = primary.flatMap(Self.screenID)

        var currentIDs = Set<NSNumber>()
        for screen in NSScreen.screens {
            guard let id = Self.screenID(screen) else { continue }
            currentIDs.insert(id)
            if id != primaryID {
                addBlackout(for: screen, id: id)
            }
        }
        for (id, window) in blackouts where !currentIDs.contains(id) || id == primaryID {
            window.orderOut(nil)
            blackouts.removeValue(forKey: id)
        }
        // Keep the kiosk window glued to the primary display on layout changes.
        if let screen = primary, let kiosk = kioskWindow {
            kiosk.setFrame(screen.frame, display: true)
        }
    }
}

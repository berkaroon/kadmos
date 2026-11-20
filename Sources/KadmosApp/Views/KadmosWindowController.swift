import AppKit
import SwiftUI

/// Native AppKit window controller hosting `EditorContentView`, providing synchronous
/// TextEdit-style window creation and foreground activation for Finder open events.
@MainActor
public final class KadmosWindowController: NSWindowController, NSWindowDelegate {
    public let store: WindowTabStore

    public init(
        store: WindowTabStore,
        settings: KadmosSettings = .shared,
        cascadingFrom anchorWindow: NSWindow? = nil
    ) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 480)
        window.title = "Kadmos"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "KadmosUnifiedToolbar")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        let hostingController = NSHostingController(
            rootView: EditorContentView(store: store, settings: settings)
        )
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 980, height: 680))

        if let anchorWindow {
            let origin = NSPoint(
                x: anchorWindow.frame.origin.x + 26,
                y: anchorWindow.frame.origin.y - 26
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
            window.setFrameAutosaveName("KadmosEditorWindow")
        }

        super.init(window: window)
        window.delegate = self
        store.hostWindow = window
        store.isFullScreen = window.styleMask.contains(.fullScreen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        store.shouldAllowWindowClose()
    }

    public func windowWillClose(_ notification: Notification) {
        AppController.shared.unregisterWindowController(self)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        AppController.shared.activeWindowID = store.windowID
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        store.isFullScreen = true
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        store.isFullScreen = false
    }
}

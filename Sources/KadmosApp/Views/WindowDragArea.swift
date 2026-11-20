import AppKit
import SwiftUI

/// Transparent AppKit view enabling native window dragging in empty titlebar/tab-strip spaces.
public struct WindowDragArea: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> DraggableTitlebarView {
        DraggableTitlebarView()
    }

    public func updateNSView(_ nsView: DraggableTitlebarView, context: Context) {}

    @MainActor
    public final class DraggableTitlebarView: NSView {
        public override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// Attaches the SwiftUI `NSWindow` to its `WindowTabStore`, tracks fullscreen and key-window state,
/// and intercepts the close button cleanly without replacing SwiftUI's internal `NSWindowDelegate`.
public struct WindowLifecycleAccessor: NSViewRepresentable {
    public let store: WindowTabStore
    @Binding public var isFullScreen: Bool

    public init(store: WindowTabStore, isFullScreen: Binding<Bool>) {
        self.store = store
        self._isFullScreen = isFullScreen
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store, isFullScreen: $isFullScreen)
    }

    public func makeNSView(context: Context) -> AccessorNSView {
        let view = AccessorNSView()
        view.onWindowAttached = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    public func updateNSView(_ nsView: AccessorNSView, context: Context) {
        context.coordinator.store = store
        context.coordinator.isFullScreen = $isFullScreen
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    @MainActor
    public final class AccessorNSView: NSView {
        var onWindowAttached: ((NSWindow) -> Void)?

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowAttached?(window)
            }
        }
    }

    @MainActor
    public final class Coordinator: NSObject {
        var store: WindowTabStore
        var isFullScreen: Binding<Bool>

        private weak var attachedWindow: NSWindow?
        private weak var originalCloseTarget: AnyObject?
        private var originalCloseAction: Selector?

        init(store: WindowTabStore, isFullScreen: Binding<Bool>) {
            self.store = store
            self.isFullScreen = isFullScreen
        }

        func attach(to window: NSWindow) {
            store.hostWindow = window
            if store.pendingBringToFront {
                store.pendingBringToFront = false
                let targetStore = store
                DispatchQueue.main.async {
                    AppController.shared.bringWindowToFront(targetStore)
                }
            }
            let fullScreen = window.styleMask.contains(.fullScreen)
            if isFullScreen.wrappedValue != fullScreen {
                DispatchQueue.main.async { [isFullScreen] in
                    isFullScreen.wrappedValue = fullScreen
                }
            }

            if let closeButton = window.standardWindowButton(.closeButton),
               closeButton.target !== self {
                originalCloseTarget = closeButton.target
                originalCloseAction = closeButton.action
                closeButton.target = self
                closeButton.action = #selector(handleCloseButton(_:))
            }

            guard attachedWindow !== window else { return }
            attachedWindow = window

            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "KadmosUnifiedToolbar")
                toolbar.showsBaselineSeparator = false
                toolbar.allowsUserCustomization = false
                toolbar.displayMode = .iconOnly
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = false

            let nc = NotificationCenter.default
            nc.removeObserver(self)
            nc.addObserver(
                self,
                selector: #selector(handleWindowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            nc.addObserver(
                self,
                selector: #selector(handleWindowDidEnterFullScreen(_:)),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            nc.addObserver(
                self,
                selector: #selector(handleWindowDidExitFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
            nc.addObserver(
                self,
                selector: #selector(handleWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
            AppController.shared.activeWindowID = store.windowID
        }

        @objc private func handleWindowDidEnterFullScreen(_ notification: Notification) {
            isFullScreen.wrappedValue = true
        }

        @objc private func handleWindowDidExitFullScreen(_ notification: Notification) {
            isFullScreen.wrappedValue = false
        }

        @objc private func handleWindowWillClose(_ notification: Notification) {
            NotificationCenter.default.removeObserver(self)
            AppController.shared.unregisterWindowStore(store)
        }

        @objc private func handleCloseButton(_ sender: Any?) {
            guard store.shouldAllowWindowClose() else {
                return
            }
            if let action = originalCloseAction, let target = originalCloseTarget {
                NSApp.sendAction(action, to: target, from: sender)
            } else {
                attachedWindow?.close()
            }
        }
    }
}

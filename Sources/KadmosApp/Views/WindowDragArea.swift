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

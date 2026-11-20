import AppKit
import KadmosCore
import SwiftUI

/// Bridges `KadmosTextView` (TextKit 1 `NSTextView` inside `NSScrollView`) cleanly into SwiftUI
/// while preserving cursor position, selection, UndoManager per tab, and IME composition.
public struct KadmosEditorRepresentable: NSViewRepresentable {
    public let tab: DocumentTab
    public let store: WindowTabStore
    public let settings: KadmosSettings
    public let isReadOnly: Bool
    public let topContentInset: CGFloat

    public init(
        tab: DocumentTab,
        store: WindowTabStore,
        settings: KadmosSettings,
        isReadOnly: Bool = false,
        topContentInset: CGFloat = 0
    ) {
        self.tab = tab
        self.store = store
        self.settings = settings
        self.isReadOnly = isReadOnly
        self.topContentInset = topContentInset
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, store: store, settings: settings)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        // Explicitly construct TextKit 1 stack (NSTextStorage -> NSLayoutManager -> NSTextContainer)
        // so custom drawBackground highlights and container word-wrap behave deterministically.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = store.wordWrap
        layoutManager.addTextContainer(textContainer)

        let textView = KadmosTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !store.wordWrap
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView

        configureCallbacks(on: textView, coordinator: context.coordinator)
        syncAllState(textView: textView, scrollView: scrollView, coordinator: context.coordinator)

        DispatchQueue.main.async { [weak textView] in
            textView?.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.tab = tab
        context.coordinator.store = store
        context.coordinator.settings = settings

        guard let textView = context.coordinator.textView else { return }
        configureCallbacks(on: textView, coordinator: context.coordinator)
        syncAllState(textView: textView, scrollView: scrollView, coordinator: context.coordinator)
    }

    private func configureCallbacks(on textView: KadmosTextView, coordinator: Coordinator) {
        textView.onZoomChange = { [weak store] newZoom in
            store?.setZoom(newZoom)
        }
        textView.onInsertTimeDate = { [weak store] in
            store?.insertTimeDate()
        }
        textView.onFindNext = { [weak store] in
            store?.findNext()
        }
        textView.onFindPrevious = { [weak store] in
            store?.findPrevious()
        }
    }

    private func syncAllState(
        textView: KadmosTextView,
        scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        let resolvedFont = settings.resolvedNSFont(zoomPercent: tab.zoomPercent)
        let spellCheck = tab.shouldEnableSpellCheck(settings: settings)

        if abs(scrollView.contentInsets.top - topContentInset) > 0.5 {
            let wasAtTop = scrollView.contentView.bounds.origin.y <= -(scrollView.contentInsets.top - 2)
            scrollView.contentInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
            if wasAtTop {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -topContentInset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        textView.configurePlainTextBehavior(
            spellCheckEnabled: spellCheck,
            autocorrectEnabled: settings.autocorrectEnabled,
            isEditableDocument: !isReadOnly && !tab.isReadOnlyLargeMode
        )

        if textView.font != resolvedFont {
            textView.font = resolvedFont
            textView.typingAttributes = [
                .font: resolvedFont,
                .foregroundColor: NSColor.textColor
            ]
        }
        textView.currentZoomPercent = tab.zoomPercent

        if coordinator.lastWordWrap != store.wordWrap {
            coordinator.lastWordWrap = store.wordWrap
            textView.applyWordWrap(store.wordWrap, in: scrollView)
        } else if store.wordWrap,
                  let container = textView.textContainer,
                  scrollView.contentSize.width > 120,
                  abs(container.containerSize.width - scrollView.contentSize.width) > 1.0 {
            textView.applyWordWrap(true, in: scrollView)
        }

        // CRITICAL: Only push string into NSTextView when tab changes or contentRevision bumps.
        // Never overwrite during user typing so cursor position and IME composition stay untouched.
        let tabChanged = coordinator.lastTabID != tab.id
        let revisionChanged = coordinator.lastContentRevision != tab.contentRevision

        if tabChanged || revisionChanged {
            coordinator.isApplyingProgrammaticUpdate = true
            defer { coordinator.isApplyingProgrammaticUpdate = false }

            let targetBuffer = tab.activeBufferText
            if textView.string != targetBuffer {
                textView.string = targetBuffer
            }
            textView.font = resolvedFont
            textView.textColor = NSColor.textColor
            textView.typingAttributes = [
                .font: resolvedFont,
                .foregroundColor: NSColor.textColor
            ]

            let maxLen = (textView.string as NSString).length
            let rawLoc = tab.selectedRange.location == NSNotFound ? 0 : tab.selectedRange.location
            let safeLoc = max(0, min(rawLoc, maxLen))
            let safeLen = max(0, min(tab.selectedRange.length, maxLen - safeLoc))
            let clampedSelection = NSRange(location: safeLoc, length: safeLen)

            textView.setSelectedRange(clampedSelection)
            if clampedSelection.location == 0 && clampedSelection.length == 0 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -topContentInset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.scrollRangeToVisible(clampedSelection)
            }

            coordinator.lastTabID = tab.id
            coordinator.lastContentRevision = tab.contentRevision
        }

        // Non-destructive visual overlays
        textView.searchMatches = store.searchMatches
        textView.currentMatchIndex = store.currentMatchIndex
        textView.trojanFindings = tab.trojanFindings
        textView.highlightTrojanChars = settings.highlightTrojanChars

        // Handle pending imperative editor command once per nonce
        if coordinator.lastHandledCommandNonce != store.pendingEditorActionNonce,
           let action = store.pendingEditorAction {
            coordinator.lastHandledCommandNonce = store.pendingEditorActionNonce
            executeEditorCommand(action, on: textView)
        }
    }

    private func executeEditorCommand(_ action: EditorCommandAction, on textView: KadmosTextView) {
        switch action {
        case .undo:
            tab.undoManager.undo()
        case .redo:
            tab.undoManager.redo()
        case .cut:
            textView.cut(nil)
        case .copy:
            textView.copy(nil)
        case .paste:
            textView.paste(nil)
        case .delete:
            textView.delete(nil)
        case .selectAll:
            textView.selectAll(nil)
        case .scrollToRange(let range):
            let total = (textView.string as NSString).length
            let loc = max(0, min(range.location, total))
            let len = max(0, min(range.length, total - loc))
            let clamped = NSRange(location: loc, length: len)
            textView.setSelectedRange(clamped)
            textView.scrollRangeToVisible(clamped)
            textView.needsDisplay = true
        case .focusEditor:
            textView.window?.makeFirstResponder(textView)
        case .printDocument:
            textView.runPrintDocument()
        case .pageSetup:
            textView.runPageSetup()
        }
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        public var tab: DocumentTab
        public var store: WindowTabStore
        public var settings: KadmosSettings

        public weak var scrollView: NSScrollView?
        public weak var textView: KadmosTextView?

        public var lastTabID: UUID?
        public var lastContentRevision: Int = -1
        public var lastWordWrap: Bool?
        public var lastHandledCommandNonce: Int = 0
        public var isApplyingProgrammaticUpdate: Bool = false

        init(tab: DocumentTab, store: WindowTabStore, settings: KadmosSettings) {
            self.tab = tab
            self.store = store
            self.settings = settings
        }

        public func undoManager(for view: NSTextView) -> UndoManager? {
            tab.undoManager
        }

        public func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate,
                  let textView = notification.object as? NSTextView,
                  !tab.isReadOnlyLargeMode else {
                return
            }

            // Defer updating Swift model until IME composition commits so marked text is never disrupted.
            if textView.hasMarkedText() {
                return
            }

            tab.text = textView.string
            tab.isDirty = true
            tab.selectedRange = textView.selectedRange()
            tab.refreshTrojanFindings(enabled: settings.highlightTrojanChars)
            store.scheduleSearch()
            store.onSessionMutated?()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate,
                  let textView = notification.object as? NSTextView else {
                return
            }
            let current = textView.selectedRange()
            if tab.selectedRange != current {
                tab.selectedRange = current
            }
        }
    }
}

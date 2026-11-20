import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Safari-style Liquid Glass tab bar integrated seamlessly into the unified `40pt` macOS 27 window header,
/// supporting inline tab/file renaming with extension editing and explicit confirmation.
public struct GlassTabBarView: View {
    public static let barHeight: CGFloat = 40

    public let store: WindowTabStore
    public let isFullScreen: Bool

    @State private var hoveredTabID: UUID?
    @State private var draggingTabID: UUID?
    @State private var middleClickMonitor: Any?

    @State private var renamingTabID: UUID?
    @State private var renameDraft: String = ""
    @State private var renameInitial: String = ""

    @Environment(\.colorScheme) private var colorScheme

    public init(store: WindowTabStore, isFullScreen: Bool) {
        self.store = store
        self.isFullScreen = isFullScreen
    }

    public var body: some View {
        ZStack {
            // Soft feathered top edge so scrolled text softens behind the floating Safari glass chrome.
            topScrollFeatherBackdrop
                .allowsHitTesting(false)

            // Empty header space remains draggable like Safari.
            WindowDragArea()

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // Exact alignment with macOS `.unifiedCompact` traffic lights (`x = 12..66`, centered at `y = 20`).
                    Color.clear
                        .frame(width: isFullScreen ? 6 : 70, height: 1)
                        .allowsHitTesting(false)

                    safariTabTrack
                        .frame(maxWidth: .infinity)

                    newTabGlassButton

                    trailingUtilityPill
                }
                .padding(.trailing, 10)
            }
        }
        .frame(height: Self.barHeight)
        .onAppear {
            installMiddleClickMonitor()
        }
        .onDisappear {
            removeMiddleClickMonitor()
        }
        .onChange(of: store.activeTabID) { _, newActiveID in
            if let renamingTabID, renamingTabID != newActiveID {
                cancelRename()
            }
        }
    }

    // MARK: - Soft Scroll-Under Feather Backdrop

    private var topScrollFeatherBackdrop: some View {
        let baseColor = Color(nsColor: .textBackgroundColor)
        return LinearGradient(
            stops: [
                .init(color: baseColor.opacity(0.88), location: 0.0),
                .init(color: baseColor.opacity(0.68), location: 0.65),
                .init(color: baseColor.opacity(0.0), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Safari Tab Track (Equal-Width / Compact / Scrollable for Many Tabs)

    @ViewBuilder
    private var safariTabTrack: some View {
        if store.tabs.count <= 1 {
            // Single-tab Safari Compact look: generous centered active glass capsule with draggable titlebar space around it.
            HStack(spacing: 0) {
                WindowDragArea()
                    .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)

                if let tab = store.activeTab ?? store.tabs.first {
                    makeTabItem(
                        tab: tab,
                        isActive: true,
                        isHovered: hoveredTabID == tab.id,
                        isSingleTab: true
                    )
                    .frame(minWidth: 240, idealWidth: 460, maxWidth: 540)
                    .frame(height: 30)
                }

                WindowDragArea()
                    .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if store.tabs.count <= 6 {
            // Classic Safari equal-width tabs inside a continuous frosted track.
            tabTrackContainer {
                HStack(spacing: 0) {
                    ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                        let isActive = tab.id == store.activeTab?.id
                        let isHovered = hoveredTabID == tab.id
                        let isRenamingThis = renamingTabID == tab.id

                        if index > 0 {
                            let prev = store.tabs[index - 1]
                            let prevActiveOrHovered = (prev.id == store.activeTab?.id) || (hoveredTabID == prev.id)
                            let currActiveOrHovered = isActive || isHovered
                            tabSeparator(visible: !prevActiveOrHovered && !currActiveOrHovered)
                        }

                        makeTabItem(tab: tab, isActive: isActive, isHovered: isHovered, isSingleTab: false)
                            .frame(minWidth: isRenamingThis ? 240 : 90, maxWidth: .infinity)
                    }
                }
                .padding(2)
            }
            .frame(height: 32)
        } else {
            // Scrollable Safari strip when > 6 tabs are open so titles remain legible.
            tabTrackContainer {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                            let isActive = tab.id == store.activeTab?.id
                            let isHovered = hoveredTabID == tab.id
                            let isRenamingThis = renamingTabID == tab.id

                            if index > 0 {
                                let prev = store.tabs[index - 1]
                                let prevActiveOrHovered = (prev.id == store.activeTab?.id) || (hoveredTabID == prev.id)
                                let currActiveOrHovered = isActive || isHovered
                                tabSeparator(visible: !prevActiveOrHovered && !currActiveOrHovered)
                            }

                            makeTabItem(tab: tab, isActive: isActive, isHovered: isHovered, isSingleTab: false)
                                .frame(minWidth: isRenamingThis ? 240 : 132, maxWidth: isRenamingThis ? 280 : 210)
                        }
                    }
                    .padding(2)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .frame(height: 32)
        }
    }

    private func tabTrackContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.085 : 0.045))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }

    private func tabSeparator(visible: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(visible ? 0.13 : 0.0))
            .frame(width: 1, height: 14)
            .animation(.easeInOut(duration: 0.12), value: visible)
    }

    private func makeTabItem(
        tab: DocumentTab,
        isActive: Bool,
        isHovered: Bool,
        isSingleTab: Bool
    ) -> some View {
        SafariTabItemView(
            tab: tab,
            isActive: isActive,
            isSingleTab: isSingleTab,
            isHovered: isHovered,
            isRenaming: renamingTabID == tab.id,
            renameDraft: $renameDraft,
            renameInitial: renameInitial,
            canCloseOthers: store.tabs.count > 1,
            hasTabsToRight: hasTabsToRight(of: tab),
            onSelect: {
                withAnimation(.snappy(duration: 0.18)) {
                    store.selectTab(tab.id)
                }
            },
            onBeginRename: {
                beginRename(for: tab)
            },
            onCommitRename: {
                commitRename(for: tab)
            },
            onCancelRename: {
                cancelRename()
            },
            onClose: {
                if renamingTabID == tab.id {
                    cancelRename()
                }
                _ = store.closeTab(tab)
            },
            onCloseOthers: { store.closeOtherTabs(except: tab) },
            onCloseRight: { store.closeTabsToRight(of: tab) },
            onDuplicate: { store.duplicateTab(tab) },
            onMoveToNewWindow: { AppController.shared.moveTabToNewWindow(tab, from: store) },
            onRevealInFinder: { revealInFinder(tab) }
        )
        .frame(height: isSingleTab ? 30 : 28)
        .onHover { hovering in
            if hovering {
                hoveredTabID = tab.id
            } else if hoveredTabID == tab.id {
                hoveredTabID = nil
            }
        }
        .onDrag {
            if renamingTabID == tab.id {
                return NSItemProvider()
            }
            draggingTabID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.plainText],
            delegate: TabReorderDropDelegate(
                targetTabID: tab.id,
                draggingTabID: $draggingTabID,
                store: store
            )
        )
    }

    // MARK: - Inline Rename State Management

    private func beginRename(for tab: DocumentTab) {
        guard !tab.isReadOnlyLargeMode else { return }
        if store.activeTabID != tab.id {
            store.selectTab(tab.id)
        }
        let editable = tab.defaultEditableFilename
        renameInitial = editable
        renameDraft = editable
        withAnimation(.snappy(duration: 0.16)) {
            renamingTabID = tab.id
        }
    }

    private func commitRename(for tab: DocumentTab) {
        guard renamingTabID == tab.id else { return }
        let candidate = renameDraft
        if store.renameTab(tab, to: candidate) {
            withAnimation(.snappy(duration: 0.16)) {
                renamingTabID = nil
            }
            renameDraft = ""
            renameInitial = ""
            store.dispatchEditorAction(.focusEditor)
        }
    }

    private func cancelRename() {
        withAnimation(.snappy(duration: 0.16)) {
            renamingTabID = nil
        }
        renameDraft = ""
        renameInitial = ""
        store.dispatchEditorAction(.focusEditor)
    }

    // MARK: - Trailing Safari Controls

    private var newTabGlassButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                _ = store.addNewTab()
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Yeni Sekme (⌘N)")
    }

    private var trailingUtilityPill: some View {
        HStack(spacing: 2) {
            Button {
                if store.isFindBarVisible {
                    store.closeFindBar()
                } else {
                    store.showFindBar(replaceExpanded: false)
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.isFindBarVisible ? Color.accentColor : Color.primary)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Bul (⌘F)")

            Button {
                store.wordWrap.toggle()
            } label: {
                Image(systemName: "text.word.spacing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.wordWrap ? Color.accentColor : Color.primary)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Sözcük Kaydırma (⌥Z)")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Ayarlar (⌘,)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func revealInFinder(_ tab: DocumentTab) {
        if let url = tab.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func hasTabsToRight(of tab: DocumentTab) -> Bool {
        guard let idx = store.tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return idx + 1 < store.tabs.count
    }

    private func installMiddleClickMonitor() {
        guard middleClickMonitor == nil else { return }
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
            if event.buttonNumber == 2,
               let targetID = hoveredTabID,
               let tab = store.tabs.first(where: { $0.id == targetID }),
               event.window === store.hostWindow {
                _ = store.closeTab(tab)
                return nil
            }
            return event
        }
    }

    private func removeMiddleClickMonitor() {
        if let middleClickMonitor {
            NSEvent.removeMonitor(middleClickMonitor)
            self.middleClickMonitor = nil
        }
    }
}

// MARK: - Safari Tab Item

private struct SafariTabItemView: View {
    let tab: DocumentTab
    let isActive: Bool
    let isSingleTab: Bool
    let isHovered: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let renameInitial: String
    let canCloseOthers: Bool
    let hasTabsToRight: Bool

    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseRight: () -> Void
    let onDuplicate: () -> Void
    let onMoveToNewWindow: () -> Void
    let onRevealInFinder: () -> Void

    @State private var isCloseHovered = false

    private var trimmedDraft: String {
        renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPendingRenameChange: Bool {
        !trimmedDraft.isEmpty && trimmedDraft != renameInitial
    }

    var body: some View {
        ZStack {
            if isRenaming {
                inlineRenameContent
            } else {
                standardTabContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Capsule())
        .modifier(SafariTabSurfaceModifier(isActive: isActive, isSingleTab: isSingleTab, isHovered: isHovered))
        .onTapGesture {
            if !isActive {
                onSelect()
            }
        }
        .contextMenu {
            Button("Adını Değiştir…", action: onBeginRename)
                .disabled(tab.isReadOnlyLargeMode)

            Divider()

            Button("Kapat", action: onClose)
            Button("Diğerlerini Kapat", action: onCloseOthers)
                .disabled(!canCloseOthers)
            Button("Sağdakileri Kapat", action: onCloseRight)
                .disabled(!hasTabsToRight)

            Divider()

            Button("Sekmeyi Çoğalt", action: onDuplicate)
            Button("Yeni Pencereye Taşı", action: onMoveToNewWindow)
                .disabled(!canCloseOthers)

            if tab.fileURL != nil {
                Divider()
                Button("Finder'da Göster", action: onRevealInFinder)
            }
        }
    }

    private var standardTabContent: some View {
        ZStack {
            // Centered icon + clickable title like Safari.
            HStack(spacing: 5) {
                Image(systemName: tab.isReadOnlyLargeMode ? "doc.text.magnifyingglass" : "doc.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if isActive && !tab.isReadOnlyLargeMode {
                    onBeginRename()
                } else {
                    onSelect()
                }
            }
            .help(isActive && !tab.isReadOnlyLargeMode ? "Dosya adını ve uzantısını değiştirmek için tıklayın" : tab.displayTitle)
            .padding(.horizontal, 24)

            // Safari-style leading close / dirty indicator slot.
            HStack {
                closeOrDirtySlot
                Spacer(minLength: 0)
            }
            .padding(.leading, 7)
        }
    }

    private var inlineRenameContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            InlineRenameTextField(
                text: $renameDraft,
                onSubmit: onCommitRename,
                onCancel: onCancelRename
            )
            .frame(maxWidth: .infinity)

            if hasPendingRenameChange {
                Button(action: onCommitRename) {
                    Label("Onayla", systemImage: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .help("Yeni adı onayla (↩)")
            }

            Button(action: onCancelRename) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("İptal (Esc)")
        }
        .padding(.horizontal, 10)
        .animation(.snappy(duration: 0.16), value: hasPendingRenameChange)
    }

    @ViewBuilder
    private var closeOrDirtySlot: some View {
        let showClose = isHovered || isCloseHovered || (!isSingleTab && isActive && !tab.isDirty)
        Button(action: onClose) {
            ZStack {
                if tab.isDirty && !isHovered && !isCloseHovered {
                    Circle()
                        .fill(isActive ? Color.accentColor : Color.secondary)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(isCloseHovered ? Color.primary : Color.secondary)
                        .opacity(showClose ? 0.9 : 0.0)
                }
            }
            .frame(width: 16, height: 16)
            .background(
                Circle()
                    .fill(isCloseHovered ? Color.primary.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isCloseHovered = hovering
        }
        .help("Sekmeyi Kapat (⌘W)")
    }
}

// MARK: - Inline NSTextField for Immediate Focus & Return/Esc Handling

private struct InlineRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> FocusAutoSelectTextField {
        let field = FocusAutoSelectTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        field.textColor = NSColor.labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.delegate = context.coordinator
        field.placeholderString = "dosya.txt"
        return field
    }

    func updateNSView(_ nsView: FocusAutoSelectTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class FocusAutoSelectTextField: NSTextField {
        private var didFocusOnce = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFocusOnce, let window else { return }
            didFocusOnce = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onCancel: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = field.stringValue
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}

private struct SafariTabSurfaceModifier: ViewModifier {
    let isActive: Bool
    let isSingleTab: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(
                    Capsule()
                        .fill(isHovered ? Color.primary.opacity(0.075) : Color.clear)
                )
        }
    }
}

// MARK: - Drag-to-Reorder Drop Delegate

private struct TabReorderDropDelegate: DropDelegate {
    let targetTabID: UUID
    @Binding var draggingTabID: UUID?
    let store: WindowTabStore

    func dropEntered(info: DropInfo) {
        guard let draggingTabID, draggingTabID != targetTabID else { return }
        withAnimation(.snappy(duration: 0.18)) {
            store.moveTab(id: draggingTabID, toTab: targetTabID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTabID = nil
        return true
    }
}

import AppKit
import Foundation
import KadmosCore
import Observation

/// Snapshot of a closed tab retained in-memory for "Reopen Closed Tab" (`⌘⇧T`).
public struct ClosedTabEntry: Sendable {
    public let fileURL: URL?
    public let bookmarkData: Data?
    public let text: String
    public let encoding: KadmosTextEncoding
    public let lineEnding: KadmosLineEnding
    public let isDirty: Bool
    public let selectedRange: NSRange
    public let zoomPercent: Int
    public let untitledNumber: Int?
}

/// Commands dispatched from SwiftUI menus/toolbars to the active `KadmosTextView`.
public enum EditorCommandAction: Equatable, Sendable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case delete
    case selectAll
    case scrollToRange(NSRange)
    case focusEditor
    case printDocument
    case pageSetup
}

/// User-facing alert banner/dialog payload.
public struct KadmosAlert: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let isError: Bool

    public init(title: String, message: String, isError: Bool = true) {
        self.title = title
        self.message = message
        self.isError = isError
    }
}

/// Manages all tabs, find/replace state, zoom, encoding, and editor commands for one window.
@Observable
@MainActor
public final class WindowTabStore: Identifiable {
    public static let standardZoomSteps: [Int] = [
        10, 25, 50, 75, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400, 500
    ]
    private static let maxClosedSnapshots = 20

    public nonisolated let windowID: UUID
    public nonisolated var id: UUID { windowID }

    @ObservationIgnored public weak var hostWindow: NSWindow?
    @ObservationIgnored public var pendingBringToFront: Bool = false
    @ObservationIgnored public var onSessionMutated: (() -> Void)?

    public var tabs: [DocumentTab]
    public var activeTabID: UUID?
    public var closedTabSnapshots: [ClosedTabEntry] = []

    // Find & Replace HUD state
    public var isFindBarVisible: Bool = false
    public var isReplaceExpanded: Bool = false
    public var findQuery: String = ""
    public var replaceQuery: String = ""
    public var searchOptions = SearchOptions()
    public var searchMatches: [NSRange] = []
    public var currentMatchIndex: Int? = nil
    public var searchTimedOut: Bool = false
    public var searchRegexError: String? = nil
    public var searchStatusBadge: String? = nil

    // Go-To-Line sheet state
    public var isGoToLinePresented: Bool = false

    // Alert state
    public var alertMessage: KadmosAlert? = nil
    public var pendingCloseTabID: UUID? = nil

    // Bridge to active KadmosTextView
    public var pendingEditorAction: EditorCommandAction? = nil
    public private(set) var pendingEditorActionNonce: Int = 0

    // Per-window word wrap & status bar overrides initialized from KadmosSettings
    public var wordWrap: Bool
    public var showStatusBar: Bool

    private var nextUntitledCounter: Int = 1
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    public init(
        windowID: UUID = UUID(),
        settings: KadmosSettings = .shared,
        createInitialTab: Bool = true
    ) {
        self.windowID = windowID
        self.wordWrap = settings.wordWrap
        self.showStatusBar = settings.showStatusBar

        if createInitialTab {
            let initial = DocumentTab(untitledNumber: 1)
            self.tabs = [initial]
            self.activeTabID = initial.id
            self.nextUntitledCounter = 2
        } else {
            self.tabs = []
            self.activeTabID = nil
            self.nextUntitledCounter = 1
        }
    }

    public var activeTab: DocumentTab? {
        if let activeTabID, let match = tabs.first(where: { $0.id == activeTabID }) {
            return match
        }
        return tabs.first
    }

    public func dispatchEditorAction(_ action: EditorCommandAction) {
        pendingEditorAction = action
        pendingEditorActionNonce &+= 1
    }

    public func clearPendingEditorAction() {
        pendingEditorAction = nil
    }

    // MARK: - Tab Creation & Switching

    @discardableResult
    public func addNewTab(select: Bool = true) -> DocumentTab {
        let number = allocateUntitledNumber()
        let tab = DocumentTab(untitledNumber: number)
        tabs.append(tab)
        if select {
            activeTabID = tab.id
            dispatchEditorAction(.focusEditor)
            scheduleSearch(immediate: true)
        }
        onSessionMutated?()
        return tab
    }

    public func insertRestoredTab(_ tab: DocumentTab, select: Bool = false) {
        tabs.append(tab)
        if select || activeTabID == nil {
            activeTabID = tab.id
        }
        if let num = tab.untitledNumber, num >= nextUntitledCounter {
            nextUntitledCounter = num + 1
        }
    }

    public func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        dispatchEditorAction(.focusEditor)
        if isFindBarVisible && !findQuery.isEmpty {
            scheduleSearch(immediate: true)
        } else {
            clearSearchResultsOnly()
        }
        onSessionMutated?()
    }

    public func selectNextTab() {
        guard tabs.count > 1, let active = activeTab,
              let idx = tabs.firstIndex(where: { $0.id == active.id }) else { return }
        let nextIndex = (idx + 1) % tabs.count
        selectTab(tabs[nextIndex].id)
    }

    public func selectPreviousTab() {
        guard tabs.count > 1, let active = activeTab,
              let idx = tabs.firstIndex(where: { $0.id == active.id }) else { return }
        let prevIndex = (idx - 1 + tabs.count) % tabs.count
        selectTab(tabs[prevIndex].id)
    }

    public func selectTab(atOneBasedIndex index: Int) {
        guard index >= 1, !tabs.isEmpty else { return }
        let resolvedIndex = (index == 9 && tabs.count > 9) ? (tabs.count - 1) : min(index - 1, tabs.count - 1)
        guard tabs.indices.contains(resolvedIndex) else { return }
        selectTab(tabs[resolvedIndex].id)
    }

    // MARK: - File Opening & Reloading

    /// Removes stray untouched empty untitled tabs (`Adsız 1`) whenever at least one real/edited tab exists.
    public func pruneEmptyPristineUntitledTabs() {
        guard tabs.contains(where: { !$0.isEmptyPristineUntitled }) else { return }
        let removedCount = tabs.count
        tabs.removeAll { $0.isEmptyPristineUntitled }
        if tabs.count != removedCount {
            if let activeTabID, !tabs.contains(where: { $0.id == activeTabID }) {
                self.activeTabID = tabs.first?.id
            }
            onSessionMutated?()
        }
    }

    public func openFile(
        url: URL,
        asEncoding: KadmosTextEncoding? = nil,
        bookmarkData: Data? = nil
    ) {
        let work: (URL) throws -> (OpenedDocumentPayload, DecodedTextResult?, KadmosLineEnding) = { targetURL in
            let payload = try DocumentSecurity.openDocument(at: targetURL, overrideEncoding: asEncoding)
            return (payload, payload.decoded, payload.detectedLineEnding)
        }

        do {
            let (payload, decodedResult, lineEnding): (OpenedDocumentPayload, DecodedTextResult?, KadmosLineEnding)
            if let bookmarkData {
                (payload, decodedResult, lineEnding) = try BookmarkStore.shared.withScopedAccess(to: bookmarkData) { scopedURL in
                    try work(scopedURL)
                }
            } else {
                (payload, decodedResult, lineEnding) = try work(url)
            }

            let canonicalURL = payload.canonicalURL
            let savedBookmark = BookmarkStore.shared.recordRecentFile(
                url: canonicalURL,
                existingBookmarkData: bookmarkData
            )

            // Focus existing tab if already open and no explicit encoding override was requested.
            if asEncoding == nil,
               let existing = tabs.first(where: { $0.fileURL == canonicalURL }) {
                if savedBookmark != nil {
                    existing.bookmarkData = savedBookmark
                }
                selectTab(existing.id)
                pruneEmptyPristineUntitledTabs()
                return
            }

            let targetTab: DocumentTab
            if let pristine = tabs.first(where: { $0.isEmptyPristineUntitled }) {
                targetTab = pristine
            } else {
                let fresh = DocumentTab(untitledNumber: nil)
                tabs.append(fresh)
                targetTab = fresh
            }

            targetTab.fileURL = canonicalURL
            targetTab.untitledNumber = nil
            targetTab.bookmarkData = savedBookmark
            targetTab.largeFileTier = payload.tier
            targetTab.streamingReader = payload.streamingReader
            targetTab.lineEnding = lineEnding
            targetTab.isDirty = false
            targetTab.undoManager.removeAllActions()
            targetTab.selectedRange = NSRange(location: 0, length: 0)
            targetTab.isTrojanBannerDismissed = false
            targetTab.isEncodingBannerDismissed = false
            targetTab.isLargeFileBannerDismissed = false

            if case .streamingReadOnly = payload.tier {
                targetTab.text = ""
                targetTab.encoding = .utf8
                targetTab.hasEncodingWarning = false
                targetTab.invalidEncodingCount = 0
                targetTab.streamingChunkText = ""
                targetTab.bumpContentRevision()
                activeTabID = targetTab.id

                Task { [weak self, weak targetTab] in
                    guard let self, let targetTab else { return }
                    await self.loadStreamingChunk(for: targetTab, atOffset: 0)
                }
            } else if let decoded = decodedResult {
                targetTab.text = decoded.text
                targetTab.encoding = decoded.encoding
                targetTab.hasEncodingWarning = decoded.hadInvalidSequences
                targetTab.invalidEncodingCount = decoded.invalidSequenceCount
                targetTab.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
                targetTab.bumpContentRevision()
                activeTabID = targetTab.id
            }

            pruneEmptyPristineUntitledTabs()
            dispatchEditorAction(.focusEditor)
            if isFindBarVisible && !findQuery.isEmpty {
                scheduleSearch(immediate: true)
            }
            onSessionMutated?()
        } catch {
            alertMessage = KadmosAlert(
                title: "Dosya Açılamadı",
                message: error.localizedDescription
            )
        }
    }

    /// Reopens the active file-backed tab with a different character encoding.
    public func reopenActiveTab(withEncoding encoding: KadmosTextEncoding) {
        guard let tab = activeTab, let url = tab.fileURL, !tab.isReadOnlyLargeMode else {
            return
        }

        if tab.isDirty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\"\(tab.displayTitle)\" dosyasını \(encoding.displayName) ile yeniden açmak istiyor musunuz?"
            alert.informativeText = "Kaydedilmemiş değişiklikleriniz kaybolacaktır."
            alert.addButton(withTitle: "Yeniden Aç")
            let cancelBtn = alert.addButton(withTitle: "İptal")
            cancelBtn.keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        let decodeBlock: (URL) throws -> (DecodedTextResult, KadmosLineEnding) = { targetURL in
            let payload = try DocumentSecurity.openDocument(at: targetURL, overrideEncoding: encoding)
            if case .streamingReadOnly = payload.tier {
                throw DocumentSecurityError.fileExceededBoundedReadLimit
            }
            guard let decoded = payload.decoded else {
                throw DocumentSecurityError.failedToReadFile(message: "Unable to decode document.")
            }
            return (decoded, payload.detectedLineEnding)
        }

        do {
            let (decoded, detectedEOL): (DecodedTextResult, KadmosLineEnding)
            if let bookmarkData = tab.bookmarkData {
                (decoded, detectedEOL) = try BookmarkStore.shared.withScopedAccess(to: bookmarkData) { scopedURL in
                    try decodeBlock(scopedURL)
                }
            } else {
                (decoded, detectedEOL) = try decodeBlock(url)
            }

            tab.text = decoded.text
            tab.encoding = decoded.encoding
            tab.lineEnding = detectedEOL
            tab.hasEncodingWarning = decoded.hadInvalidSequences
            tab.invalidEncodingCount = decoded.invalidSequenceCount
            tab.isEncodingBannerDismissed = false
            tab.isDirty = false
            tab.undoManager.removeAllActions()
            tab.selectedRange = NSRange(location: 0, length: 0)
            tab.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
            tab.bumpContentRevision()
            scheduleSearch(immediate: true)
            onSessionMutated?()
        } catch {
            alertMessage = KadmosAlert(
                title: "Kodlama ile Yeniden Açılamadı",
                message: error.localizedDescription
            )
        }
    }

    /// Loads a bounded 256 KB UTF-8 chunk for a >1 GB read-only streaming document.
    public func loadStreamingChunk(for tab: DocumentTab, atOffset offset: Int64) async {
        guard let reader = tab.streamingReader else { return }
        let clampedOffset = max(0, min(offset, reader.totalBytes))

        do {
            let result: (
                text: String,
                nextOffset: Int64,
                prevOffset: Int64,
                actualStart: Int64,
                actualEnd: Int64,
                hadInvalidSequences: Bool
            )
            if let bookmarkData = tab.bookmarkData {
                result = try await BookmarkStore.shared.withScopedAccess(to: bookmarkData) { _ in
                    try await reader.readChunk(atOffset: clampedOffset)
                }
            } else {
                result = try await reader.readChunk(atOffset: clampedOffset)
            }

            tab.streamingChunkText = LineEndingCodec.normalizeToLF(result.text)
            tab.streamingActualStart = result.actualStart
            tab.streamingActualEnd = result.actualEnd
            tab.streamingPrevOffset = result.prevOffset
            tab.streamingNextOffset = result.nextOffset
            tab.hasEncodingWarning = result.hadInvalidSequences
            tab.selectedRange = NSRange(location: 0, length: 0)
            tab.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
            tab.bumpContentRevision()

            if isFindBarVisible && !findQuery.isEmpty {
                scheduleSearch(immediate: true)
            }
        } catch {
            alertMessage = KadmosAlert(
                title: "Akış Parçası Okunamadı",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Encoding & Line Ending Conversion

    public func convertEncoding(_ encoding: KadmosTextEncoding) {
        guard let tab = activeTab, !tab.isReadOnlyLargeMode else { return }
        if tab.encoding == encoding { return }

        if !TextEncodingCodec.canLosslesslyEncode(tab.text, as: encoding) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(encoding.displayName) kodlamasına dönüştürülsün mü?"
            alert.informativeText = "Belgede bu kodlamayla kayıpsız temsil edilemeyen karakterler var. Kaydetme sırasında veri kaybı yaşanabilir."
            alert.addButton(withTitle: "Dönüştür")
            let cancelBtn = alert.addButton(withTitle: "İptal")
            cancelBtn.keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        tab.encoding = encoding
        tab.isDirty = true
        onSessionMutated?()
    }

    public func convertLineEnding(_ lineEnding: KadmosLineEnding) {
        guard let tab = activeTab, !tab.isReadOnlyLargeMode else { return }
        if tab.lineEnding == lineEnding { return }
        tab.lineEnding = lineEnding
        tab.isDirty = true
        onSessionMutated?()
    }

    // MARK: - Inline Tab Renaming

    /// Renames an untitled tab (`customFilename`) or file-backed tab safely within its parent directory (`SECURITY.md` §3.4).
    @discardableResult
    public func renameTab(_ tab: DocumentTab, to rawNewName: String) -> Bool {
        guard !tab.isReadOnlyLargeMode else { return false }

        let trimmed = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSingleFilename(trimmed) else {
            alertMessage = KadmosAlert(
                title: "Geçersiz Dosya Adı",
                message: "Dosya adı boş olamaz; '/', '\\' veya denetim karakterleri içeremez."
            )
            return false
        }

        guard let currentURL = tab.fileURL else {
            tab.customFilename = trimmed
            onSessionMutated?()
            return true
        }

        if trimmed == currentURL.lastPathComponent {
            return true
        }

        let parentDir = currentURL.deletingLastPathComponent()
        let attemptMove: (URL) throws -> URL = { scopedURL in
            let dir = scopedURL.deletingLastPathComponent()
            let destination = dir.appendingPathComponent(trimmed, isDirectory: false)
            guard DocumentSecurity.validateWithinScope(candidate: destination, allowedRoot: dir) else {
                throw DocumentSecurityError.pathOutsideAllowedScope
            }
            try FileManager.default.moveItem(at: scopedURL, to: destination)
            return DocumentSecurity.resolveCanonicalURL(destination).resolved
        }

        do {
            let movedURL: URL
            if let existingBookmark = tab.bookmarkData {
                movedURL = try BookmarkStore.shared.withScopedAccess(to: existingBookmark) { scopedURL in
                    try attemptMove(scopedURL)
                }
            } else {
                movedURL = try attemptMove(currentURL)
            }

            tab.fileURL = movedURL
            tab.customFilename = nil
            tab.bookmarkData = BookmarkStore.shared.recordRecentFile(url: movedURL, existingBookmarkData: nil)
            onSessionMutated?()
            return true
        } catch let error as NSError where isSandboxOrPermissionError(error) {
            // App Sandbox single-file Powerbox tokens grant access only to the original file URL;
            // present NSSavePanel pre-filled with the new name in the same directory so the user can confirm.
            let panel = NSSavePanel()
            panel.title = "Dosya Adını Değiştir / Kaydet"
            panel.directoryURL = parentDir
            panel.nameFieldStringValue = trimmed
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            guard panel.runModal() == .OK, let chosenURL = panel.url else {
                return false
            }
            return writeTab(tab, to: chosenURL, encoding: tab.encoding, existingBookmark: nil)
        } catch {
            alertMessage = KadmosAlert(
                title: "Dosya Adı Değiştirilemedi",
                message: error.localizedDescription
            )
            return false
        }
    }

    private func isValidSingleFilename(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            return false
        }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || (scalar.value >= 0x80 && scalar.value <= 0x9F) {
                return false
            }
        }
        return true
    }

    private func isSandboxOrPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            return true
        }
        return false
    }

    // MARK: - Saving

    @discardableResult
    public func saveActiveTab() -> Bool {
        guard let tab = activeTab else { return false }
        return saveTab(tab)
    }

    @discardableResult
    public func saveActiveTabAs() -> Bool {
        guard let tab = activeTab else { return false }
        return saveTabAs(tab)
    }

    @discardableResult
    public func saveTab(_ tab: DocumentTab) -> Bool {
        guard !tab.isReadOnlyLargeMode else { return false }
        guard let targetURL = tab.fileURL else {
            return saveTabAs(tab)
        }
        return writeTab(tab, to: targetURL, encoding: tab.encoding, existingBookmark: tab.bookmarkData)
    }

    @discardableResult
    public func saveTabAs(_ tab: DocumentTab) -> Bool {
        guard !tab.isReadOnlyLargeMode else { return false }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let currentURL = tab.fileURL {
            panel.directoryURL = currentURL.deletingLastPathComponent()
            panel.nameFieldStringValue = currentURL.lastPathComponent
        } else {
            panel.nameFieldStringValue = tab.defaultEditableFilename
        }

        let accessory = SaveEncodingAccessoryView(initialEncoding: tab.encoding)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return false
        }

        let chosenEncoding = accessory.selectedEncoding
        return writeTab(tab, to: selectedURL, encoding: chosenEncoding, existingBookmark: nil)
    }

    public func saveAllTabs() {
        for tab in tabs where tab.isDirty && !tab.isReadOnlyLargeMode {
            if !saveTab(tab) {
                break
            }
        }
    }

    private func writeTab(
        _ tab: DocumentTab,
        to url: URL,
        encoding: KadmosTextEncoding,
        existingBookmark: Data?
    ) -> Bool {
        let serialized = LineEndingCodec.serialize(tab.text, as: tab.lineEnding)
        var effectiveEncoding = encoding
        let dataToWrite: Data

        do {
            dataToWrite = try TextEncodingCodec.encode(serialized, as: effectiveEncoding, allowLossy: false)
        } catch TextEncodingError.unrepresentableCharacters {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(effectiveEncoding.displayName) kodlaması bazı karakterleri desteklemiyor"
            alert.informativeText = "Karakter kaybını önlemek için UTF-8 olarak kaydedebilir veya kayıplı dönüştürebilirsiniz."
            alert.addButton(withTitle: "UTF-8 Olarak Kaydet")
            let cancelBtn = alert.addButton(withTitle: "İptal")
            cancelBtn.keyEquivalent = "\u{1b}"
            let lossyBtn = alert.addButton(withTitle: "Kayıplı Kaydet")
            lossyBtn.hasDestructiveAction = true

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                effectiveEncoding = .utf8
                guard let utf8Data = try? TextEncodingCodec.encode(serialized, as: .utf8, allowLossy: false) else {
                    return false
                }
                dataToWrite = utf8Data
            case .alertThirdButtonReturn:
                guard let lossyData = try? TextEncodingCodec.encode(serialized, as: effectiveEncoding, allowLossy: true) else {
                    return false
                }
                dataToWrite = lossyData
            default:
                return false
            }
        } catch {
            alertMessage = KadmosAlert(title: "Kodlama Hatası", message: error.localizedDescription)
            return false
        }

        do {
            let savedCanonicalURL: URL
            if let existingBookmark {
                savedCanonicalURL = try BookmarkStore.shared.withScopedAccess(to: existingBookmark) { scopedURL in
                    try DocumentSecurity.atomicSave(data: dataToWrite, to: scopedURL)
                    return DocumentSecurity.resolveCanonicalURL(scopedURL).resolved
                }
            } else {
                try DocumentSecurity.atomicSave(data: dataToWrite, to: url)
                savedCanonicalURL = DocumentSecurity.resolveCanonicalURL(url).resolved
            }

            tab.fileURL = savedCanonicalURL
            tab.untitledNumber = nil
            tab.customFilename = nil
            tab.encoding = effectiveEncoding
            tab.isDirty = false
            tab.bookmarkData = BookmarkStore.shared.recordRecentFile(
                url: savedCanonicalURL,
                existingBookmarkData: existingBookmark
            )
            onSessionMutated?()
            return true
        } catch {
            alertMessage = KadmosAlert(
                title: "Dosya Kaydedilemedi",
                message: error.localizedDescription
            )
            return false
        }
    }

    // MARK: - Closing, Duplicating, Reordering & Reopening Tabs

    public func closeActiveTab() {
        guard let tab = activeTab else { return }
        _ = closeTab(tab)
    }

    @discardableResult
    public func closeTab(_ tab: DocumentTab) -> Bool {
        if tab.isDirty {
            let decision = promptUnsavedChanges(for: tab)
            switch decision {
            case .save:
                guard saveTab(tab) else { return false }
            case .discard:
                break
            case .cancel:
                return false
            }
        }

        // If closing the sole empty pristine untitled tab, close the window itself.
        if tabs.count == 1 && tab.isEmptyPristineUntitled {
            requestWindowClose()
            return true
        }

        pushClosedSnapshot(for: tab)
        removeTabUnchecked(tab)
        if tabs.isEmpty {
            _ = addNewTab(select: true)
        }
        onSessionMutated?()
        return true
    }

    public func closeOtherTabs(except keeper: DocumentTab) {
        let targets = tabs.filter { $0.id != keeper.id }
        closeBatch(targets)
        activeTabID = keeper.id
    }

    public func closeTabsToRight(of anchor: DocumentTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == anchor.id }), idx + 1 < tabs.count else {
            return
        }
        let targets = Array(tabs[(idx + 1)...])
        closeBatch(targets)
    }

    private func closeBatch(_ targets: [DocumentTab]) {
        for tab in targets {
            if tab.isDirty {
                activeTabID = tab.id
                switch promptUnsavedChanges(for: tab) {
                case .save:
                    guard saveTab(tab) else { return }
                case .discard:
                    break
                case .cancel:
                    return
                }
            }
            pushClosedSnapshot(for: tab)
            removeTabUnchecked(tab)
        }
        if tabs.isEmpty {
            _ = addNewTab(select: true)
        }
        onSessionMutated?()
    }

    /// Prompts for all dirty tabs before closing the entire window.
    public func confirmCloseAllTabsForWindowClose() -> Bool {
        for tab in tabs where tab.isDirty {
            activeTabID = tab.id
            switch promptUnsavedChanges(for: tab) {
            case .save:
                if !saveTab(tab) {
                    return false
                }
            case .discard:
                continue
            case .cancel:
                return false
            }
        }
        return true
    }

    /// Evaluates whether the window is permitted to close (persisting session if continuing last window).
    public func shouldAllowWindowClose() -> Bool {
        if KadmosSettings.shared.startupBehavior == .continuePreviousSession {
            AppController.shared.persistSessionNow()
            if AppController.shared.windows.count <= 1 {
                return true
            }
        }
        return confirmCloseAllTabsForWindowClose()
    }

    /// Closes the host window after confirming any unsaved changes.
    public func requestWindowClose() {
        guard shouldAllowWindowClose() else { return }
        hostWindow?.close()
    }

    public func duplicateTab(_ tab: DocumentTab) {
        let number = allocateUntitledNumber()
        let copy = DocumentTab(
            fileURL: nil,
            untitledNumber: number,
            text: tab.activeBufferText,
            encoding: tab.encoding,
            lineEnding: tab.lineEnding,
            isDirty: !tab.activeBufferText.isEmpty,
            zoomPercent: tab.zoomPercent
        )
        copy.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.insert(copy, at: idx + 1)
        } else {
            tabs.append(copy)
        }
        activeTabID = copy.id
        dispatchEditorAction(.focusEditor)
        onSessionMutated?()
    }

    public func detachTabForNewWindow(_ tab: DocumentTab) -> DocumentTab? {
        guard tabs.count > 1 else { return nil }
        removeTabUnchecked(tab)
        onSessionMutated?()
        return tab
    }

    public func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = tabs
        let itemsToMove = source.sorted().map { reordered[$0] }
        for idx in source.sorted(by: >) {
            reordered.remove(at: idx)
        }
        let adjustedDest = destination - source.filter { $0 < destination }.count
        let safeDest = max(0, min(adjustedDest, reordered.count))
        reordered.insert(contentsOf: itemsToMove, at: safeDest)
        tabs = reordered
        onSessionMutated?()
    }

    public func moveTab(id: UUID, toTab targetID: UUID) {
        guard id != targetID,
              let fromIdx = tabs.firstIndex(where: { $0.id == id }),
              let toIdx = tabs.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        var updated = tabs
        let moved = updated.remove(at: fromIdx)
        updated.insert(moved, at: toIdx)
        tabs = updated
        onSessionMutated?()
    }

    public func reopenClosedTab() {
        guard let snapshot = closedTabSnapshots.popLast() else { return }

        if let url = snapshot.fileURL, !snapshot.isDirty {
            openFile(url: url, asEncoding: nil, bookmarkData: snapshot.bookmarkData)
            return
        }

        let restored = DocumentTab(
            fileURL: snapshot.fileURL,
            untitledNumber: snapshot.fileURL == nil ? (snapshot.untitledNumber ?? allocateUntitledNumber()) : nil,
            text: snapshot.text,
            encoding: snapshot.encoding,
            lineEnding: snapshot.lineEnding,
            isDirty: snapshot.isDirty,
            zoomPercent: snapshot.zoomPercent,
            selectedRange: snapshot.selectedRange,
            bookmarkData: snapshot.bookmarkData
        )
        restored.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)

        if tabs.count == 1 && tabs[0].isEmptyPristineUntitled {
            tabs[0] = restored
        } else {
            tabs.append(restored)
        }
        activeTabID = restored.id
        dispatchEditorAction(.focusEditor)
        onSessionMutated?()
    }

    private enum UnsavedDecision {
        case save
        case discard
        case cancel
    }

    private func promptUnsavedChanges(for tab: DocumentTab) -> UnsavedDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\"\(tab.displayTitle)\" belgesindeki değişiklikleri kaydetmek istiyor musunuz?"
        alert.informativeText = "Kaydetmezseniz yaptığınız değişiklikler kalıcı olarak kaybolacaktır."
        alert.addButton(withTitle: "Kaydet")
        let cancelBtn = alert.addButton(withTitle: "İptal")
        cancelBtn.keyEquivalent = "\u{1b}"
        let discardBtn = alert.addButton(withTitle: "Kaydetme")
        discardBtn.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertThirdButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func pushClosedSnapshot(for tab: DocumentTab) {
        guard !tab.isEmptyPristineUntitled else { return }
        let entry = ClosedTabEntry(
            fileURL: tab.fileURL,
            bookmarkData: tab.bookmarkData,
            text: tab.isReadOnlyLargeMode ? "" : tab.text,
            encoding: tab.encoding,
            lineEnding: tab.lineEnding,
            isDirty: tab.isDirty,
            selectedRange: tab.selectedRange,
            zoomPercent: tab.zoomPercent,
            untitledNumber: tab.untitledNumber
        )
        closedTabSnapshots.append(entry)
        if closedTabSnapshots.count > Self.maxClosedSnapshots {
            closedTabSnapshots.removeFirst(closedTabSnapshots.count - Self.maxClosedSnapshots)
        }
    }

    private func removeTabUnchecked(_ tab: DocumentTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasActive = (activeTabID == tab.id)
        tabs.remove(at: idx)
        if wasActive {
            if tabs.indices.contains(idx) {
                activeTabID = tabs[idx].id
            } else {
                activeTabID = tabs.last?.id
            }
        }
    }

    private func allocateUntitledNumber() -> Int {
        let usedNumbers = Set(tabs.compactMap(\.untitledNumber))
        var candidate = 1
        while usedNumbers.contains(candidate) {
            candidate += 1
        }
        nextUntitledCounter = max(nextUntitledCounter, candidate + 1)
        return candidate
    }

    // MARK: - Zoom

    public func zoomIn() {
        guard let tab = activeTab else { return }
        let current = tab.zoomPercent
        if let next = Self.standardZoomSteps.first(where: { $0 > current }) {
            tab.zoomPercent = next
        } else {
            tab.zoomPercent = 500
        }
        onSessionMutated?()
    }

    public func zoomOut() {
        guard let tab = activeTab else { return }
        let current = tab.zoomPercent
        if let prev = Self.standardZoomSteps.last(where: { $0 < current }) {
            tab.zoomPercent = prev
        } else {
            tab.zoomPercent = 10
        }
        onSessionMutated?()
    }

    public func resetZoom() {
        guard let tab = activeTab else { return }
        tab.zoomPercent = 100
        onSessionMutated?()
    }

    public func setZoom(_ percent: Int) {
        guard let tab = activeTab else { return }
        tab.zoomPercent = max(10, min(percent, 500))
        onSessionMutated?()
    }

    // MARK: - Time/Date Insert (F5)

    public func insertTimeDate() {
        guard let tab = activeTab, !tab.isReadOnlyLargeMode else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "HH:mm dd.MM.yyyy"
        let stamp = formatter.string(from: Date())

        let nsText = tab.text as NSString
        let safeLoc = max(0, min(tab.selectedRange.location, nsText.length))
        let safeLen = max(0, min(tab.selectedRange.length, nsText.length - safeLoc))
        let replaceRange = NSRange(location: safeLoc, length: safeLen)

        let updatedText = nsText.replacingCharacters(in: replaceRange, with: stamp)
        let newCaret = NSRange(location: safeLoc + (stamp as NSString).length, length: 0)

        applyUndoableBufferEdit(
            on: tab,
            newText: updatedText,
            newSelection: newCaret,
            actionName: "Saat ve Tarih Ekle"
        )
    }

    // MARK: - Safe Find & Replace

    public func showFindBar(replaceExpanded: Bool = false) {
        if let tab = activeTab, tab.selectedRange.length > 0 {
            let nsText = tab.activeBufferText as NSString
            let safeLoc = max(0, min(tab.selectedRange.location, nsText.length))
            let safeLen = max(0, min(tab.selectedRange.length, nsText.length - safeLoc))
            if safeLen > 0, safeLen <= 256 {
                let selected = nsText.substring(with: NSRange(location: safeLoc, length: safeLen))
                if !selected.contains("\n") && !selected.contains("\r") {
                    findQuery = selected
                }
            }
        }
        isFindBarVisible = true
        if replaceExpanded {
            isReplaceExpanded = true
        }
        if !findQuery.isEmpty {
            scheduleSearch(immediate: true)
        }
    }

    public func closeFindBar() {
        searchTask?.cancel()
        searchTask = nil
        isFindBarVisible = false
        clearSearchResultsOnly()
        dispatchEditorAction(.focusEditor)
    }

    public func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()

        guard isFindBarVisible, !findQuery.isEmpty, let tab = activeTab else {
            clearSearchResultsOnly()
            return
        }

        let query = findQuery
        let options = searchOptions
        let targetTabID = tab.id
        let buffer = tab.activeBufferText
        let caretLoc = tab.selectedRange.location == NSNotFound ? 0 : tab.selectedRange.location

        searchTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled, let self else { return }

            let outcome = await SafeSearchEngine.findAll(
                query: query,
                in: buffer,
                options: options
            )

            guard !Task.isCancelled, self.activeTab?.id == targetTabID else { return }

            switch outcome {
            case .matches(let ranges):
                self.searchTimedOut = false
                self.searchRegexError = nil
                self.searchMatches = ranges
                if ranges.isEmpty {
                    self.currentMatchIndex = nil
                    self.searchStatusBadge = "Eşleşme yok"
                } else {
                    let chosen = SafeSearchEngine.nextMatchIndex(
                        in: ranges,
                        from: caretLoc,
                        wrapAround: options.wrapAround
                    ) ?? 0
                    self.currentMatchIndex = chosen
                    self.searchStatusBadge = "\(chosen + 1) / \(ranges.count)"
                }

            case .invalidRegex(let errorMessage):
                self.searchTimedOut = false
                self.searchRegexError = errorMessage
                self.searchMatches = []
                self.currentMatchIndex = nil
                self.searchStatusBadge = "Geçersiz regex"

            case .timedOut:
                self.searchTimedOut = true
                self.searchRegexError = nil
                self.searchMatches = []
                self.currentMatchIndex = nil
                self.searchStatusBadge = "Zaman aşımı"
            }
        }
    }

    public func findNext() {
        guard let tab = activeTab else { return }
        if !isFindBarVisible {
            showFindBar(replaceExpanded: false)
            return
        }
        guard !findQuery.isEmpty else { return }

        if searchMatches.isEmpty {
            Task { [weak self] in
                await self?.runImmediateSearchAndStep(forward: true)
            }
            return
        }

        let cursorStart: Int
        if let idx = currentMatchIndex,
           searchMatches.indices.contains(idx),
           tab.selectedRange == searchMatches[idx] {
            cursorStart = tab.selectedRange.location + max(1, tab.selectedRange.length)
        } else {
            cursorStart = tab.selectedRange.location == NSNotFound ? 0 : tab.selectedRange.location
        }

        guard let nextIdx = SafeSearchEngine.nextMatchIndex(
            in: searchMatches,
            from: cursorStart,
            wrapAround: searchOptions.wrapAround
        ) else {
            NSSound.beep()
            return
        }

        jumpToMatch(at: nextIdx, in: tab)
    }

    public func findPrevious() {
        guard let tab = activeTab else { return }
        if !isFindBarVisible {
            showFindBar(replaceExpanded: false)
            return
        }
        guard !findQuery.isEmpty else { return }

        if searchMatches.isEmpty {
            Task { [weak self] in
                await self?.runImmediateSearchAndStep(forward: false)
            }
            return
        }

        let cursorLoc = tab.selectedRange.location == NSNotFound ? 0 : tab.selectedRange.location
        guard let prevIdx = SafeSearchEngine.previousMatchIndex(
            in: searchMatches,
            before: cursorLoc,
            wrapAround: searchOptions.wrapAround
        ) else {
            NSSound.beep()
            return
        }

        jumpToMatch(at: prevIdx, in: tab)
    }

    public func replaceCurrent() {
        guard let tab = activeTab, !tab.isReadOnlyLargeMode, !findQuery.isEmpty else { return }

        let targetIndex: Int?
        if let current = currentMatchIndex,
           searchMatches.indices.contains(current),
           tab.selectedRange == searchMatches[current] {
            targetIndex = current
        } else {
            let loc = tab.selectedRange.location == NSNotFound ? 0 : tab.selectedRange.location
            targetIndex = SafeSearchEngine.nextMatchIndex(
                in: searchMatches,
                from: loc,
                wrapAround: searchOptions.wrapAround
            )
        }

        guard let idx = targetIndex, searchMatches.indices.contains(idx) else {
            NSSound.beep()
            return
        }

        let matchRange = searchMatches[idx]
        guard let updatedText = SafeSearchEngine.replacingMatch(
            in: tab.text,
            range: matchRange,
            with: replaceQuery,
            query: findQuery,
            options: searchOptions
        ) else {
            return
        }

        let lengthDelta = (updatedText as NSString).length - (tab.text as NSString).length
        let newLocation = matchRange.location + max(0, matchRange.length + lengthDelta)
        let newSelection = NSRange(location: newLocation, length: 0)

        applyUndoableBufferEdit(
            on: tab,
            newText: updatedText,
            newSelection: newSelection,
            actionName: "Değiştir"
        )

        Task { [weak self] in
            await self?.runImmediateSearchAndStep(forward: true)
        }
    }

    public func replaceAll() async {
        guard let tab = activeTab, !tab.isReadOnlyLargeMode, !findQuery.isEmpty else { return }
        searchTask?.cancel()

        let outcome = await SafeSearchEngine.replacingAll(
            query: findQuery,
            in: tab.text,
            with: replaceQuery,
            options: searchOptions
        )

        switch outcome {
        case .replaced(let updatedText, let count):
            if count > 0 {
                applyUndoableBufferEdit(
                    on: tab,
                    newText: updatedText,
                    newSelection: NSRange(location: 0, length: 0),
                    actionName: "Tümünü Değiştir"
                )
            }
            searchTimedOut = false
            searchRegexError = nil
            searchMatches = []
            currentMatchIndex = nil
            searchStatusBadge = count > 0 ? "\(count) değişiklik" : "Eşleşme yok"

        case .invalidRegex(let errorMessage):
            searchTimedOut = false
            searchRegexError = errorMessage
            searchStatusBadge = "Geçersiz regex"

        case .timedOut:
            searchTimedOut = true
            searchRegexError = nil
            searchStatusBadge = "Zaman aşımı"
        }
    }

    private func runImmediateSearchAndStep(forward: Bool) async {
        guard let tab = activeTab, !findQuery.isEmpty else { return }
        let outcome = await SafeSearchEngine.findAll(
            query: findQuery,
            in: tab.activeBufferText,
            options: searchOptions
        )
        guard activeTab?.id == tab.id else { return }

        switch outcome {
        case .matches(let ranges):
            searchTimedOut = false
            searchRegexError = nil
            searchMatches = ranges
            guard !ranges.isEmpty else {
                currentMatchIndex = nil
                searchStatusBadge = "Eşleşme yok"
                NSSound.beep()
                return
            }
            let loc = tab.selectedRange.location == NSNotFound ? 0 : tab.selectedRange.location
            let idx = forward
                ? (SafeSearchEngine.nextMatchIndex(in: ranges, from: loc, wrapAround: searchOptions.wrapAround) ?? 0)
                : (SafeSearchEngine.previousMatchIndex(in: ranges, before: loc, wrapAround: searchOptions.wrapAround) ?? (ranges.count - 1))
            jumpToMatch(at: idx, in: tab)

        case .invalidRegex(let errorMessage):
            searchTimedOut = false
            searchRegexError = errorMessage
            searchMatches = []
            currentMatchIndex = nil
            searchStatusBadge = "Geçersiz regex"

        case .timedOut:
            searchTimedOut = true
            searchRegexError = nil
            searchMatches = []
            currentMatchIndex = nil
            searchStatusBadge = "Zaman aşımı"
        }
    }

    private func jumpToMatch(at index: Int, in tab: DocumentTab) {
        guard searchMatches.indices.contains(index) else { return }
        let range = searchMatches[index]
        currentMatchIndex = index
        searchStatusBadge = "\(index + 1) / \(searchMatches.count)"
        tab.selectedRange = range
        dispatchEditorAction(.scrollToRange(range))
    }

    private func clearSearchResultsOnly() {
        searchMatches = []
        currentMatchIndex = nil
        searchTimedOut = false
        searchRegexError = nil
        searchStatusBadge = nil
    }

    // MARK: - Go To Line

    @discardableResult
    public func goToLine(_ oneBasedLine: Int) -> Bool {
        guard let tab = activeTab else { return false }
        let buffer = tab.activeBufferText as NSString
        guard let offset = LineColumnCalculator.utf16Offset(forLine: oneBasedLine, in: buffer) else {
            return false
        }
        let target = NSRange(location: offset, length: 0)
        tab.selectedRange = target
        dispatchEditorAction(.scrollToRange(target))
        dispatchEditorAction(.focusEditor)
        return true
    }

    // MARK: - Undoable Programmatic Edit Helper

    private func applyUndoableBufferEdit(
        on tab: DocumentTab,
        newText: String,
        newSelection: NSRange,
        actionName: String
    ) {
        let oldText = tab.text
        let oldSelection = tab.selectedRange
        let oldDirty = tab.isDirty

        registerUndoBufferTransition(
            tab: tab,
            fromText: oldText,
            fromSelection: oldSelection,
            fromDirty: oldDirty,
            toText: newText,
            toSelection: newSelection,
            toDirty: true,
            actionName: actionName
        )

        tab.text = newText
        tab.selectedRange = newSelection
        tab.isDirty = true
        tab.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
        tab.bumpContentRevision()
        dispatchEditorAction(.scrollToRange(newSelection))
        onSessionMutated?()
    }

    private func registerUndoBufferTransition(
        tab: DocumentTab,
        fromText: String,
        fromSelection: NSRange,
        fromDirty: Bool,
        toText: String,
        toSelection: NSRange,
        toDirty: Bool,
        actionName: String
    ) {
        tab.undoManager.registerUndo(withTarget: self) { [weak tab] store in
            guard let tab else { return }
            store.registerUndoBufferTransition(
                tab: tab,
                fromText: toText,
                fromSelection: toSelection,
                fromDirty: toDirty,
                toText: fromText,
                toSelection: fromSelection,
                toDirty: fromDirty,
                actionName: actionName
            )
            tab.text = fromText
            tab.selectedRange = fromSelection
            tab.isDirty = fromDirty
            tab.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
            tab.bumpContentRevision()
            store.dispatchEditorAction(.scrollToRange(fromSelection))
            store.onSessionMutated?()
        }
        tab.undoManager.setActionName(actionName)
    }
}

/// Compact `NSSavePanel` accessory view allowing users to pick the target character encoding on Save As.
@MainActor
private final class SaveEncodingAccessoryView: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    var selectedEncoding: KadmosTextEncoding {
        let idx = popup.indexOfSelectedItem
        let all = KadmosTextEncoding.allCases
        return all.indices.contains(idx) ? all[idx] : .utf8
    }

    init(initialEncoding: KadmosTextEncoding) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 38))
        let label = NSTextField(labelWithString: "Kodlama:")
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false

        for encoding in KadmosTextEncoding.allCases {
            popup.addItem(withTitle: encoding.displayName)
        }
        if let idx = KadmosTextEncoding.allCases.firstIndex(of: initialEncoding) {
            popup.selectItem(at: idx)
        }
        popup.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(popup)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

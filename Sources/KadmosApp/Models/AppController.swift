import AppKit
import Foundation
import KadmosCore
import Observation

/// Central application coordinator owning open window tab stores, `SessionVault` persistence,
/// `kadmos://` URL routing (`SECURITY.md` §5), and open/save panels.
@Observable
@MainActor
public final class AppController {
    public static let shared = AppController()

    public let sessionVault = SessionVault()
    public private(set) var windows: [WindowTabStore] = []
    public var activeWindowID: UUID?

    @ObservationIgnored private var pendingWindowStores: [WindowTabStore] = []
    @ObservationIgnored private var openNewWindowAction: (() -> Void)?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var hasAttemptedInitialRestore = false

    private init() {}

    /// Currently active `WindowTabStore` (key window first, then `activeWindowID`, then first window).
    public var activeWindowStore: WindowTabStore? {
        if let keyWindow = NSApp?.keyWindow,
           let match = windows.first(where: { $0.hostWindow === keyWindow }) {
            return match
        }
        if let activeWindowID,
           let match = windows.first(where: { $0.windowID == activeWindowID }) {
            return match
        }
        return windows.first
    }

    /// Activates the application using both macOS 14+ cooperative activation and legacy fallback.
    public func activateApplication() {
        NSApp?.activate()
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// Activates Kadmos, unminiaturizes if needed, orders the target window to front, and focuses the editor.
    public func bringWindowToFront(_ store: WindowTabStore) {
        activateApplication()
        guard let window = store.hostWindow else {
            store.pendingBringToFront = true
            return
        }
        store.pendingBringToFront = false
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        store.dispatchEditorAction(.focusEditor)

        DispatchQueue.main.async { [weak self, weak window, weak store] in
            guard let self, let window, let store else { return }
            self.activateApplication()
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            store.dispatchEditorAction(.focusEditor)
        }
    }

    /// Registers SwiftUI's `openWindow(id: "editor")` closure for programmatic multi-window creation.
    public func registerOpenWindowHandler(_ handler: @escaping () -> Void) {
        openNewWindowAction = handler
        if !pendingWindowStores.isEmpty {
            let pendingCount = pendingWindowStores.count
            for _ in 0..<pendingCount {
                handler()
            }
        }
    }

    /// Claims a pending `WindowTabStore` or creates/restores a store when a SwiftUI `WindowGroup` scene mounts.
    public func claimOrCreateWindowStore() -> WindowTabStore {
        if !pendingWindowStores.isEmpty {
            let store = pendingWindowStores.removeFirst()
            registerWindowStore(store)
            return store
        }

        if !hasAttemptedInitialRestore {
            hasAttemptedInitialRestore = true
            if KadmosSettings.shared.startupBehavior == .continuePreviousSession,
               let restored = restoreSessionIntoStore() {
                registerWindowStore(restored)
                return restored
            }
        }

        let fresh = WindowTabStore(settings: KadmosSettings.shared, createInitialTab: true)
        registerWindowStore(fresh)
        return fresh
    }

    public func registerWindowStore(_ store: WindowTabStore) {
        if !windows.contains(where: { $0.windowID == store.windowID }) {
            windows.append(store)
        }
        store.onSessionMutated = { [weak self] in
            self?.scheduleSessionPersist()
        }
        activeWindowID = store.windowID
    }

    public func unregisterWindowStore(_ store: WindowTabStore) {
        windows.removeAll { $0.windowID == store.windowID }
        if activeWindowID == store.windowID {
            activeWindowID = windows.first?.windowID
        }
        scheduleSessionPersist()
    }

    /// Opens a brand-new editor window (`⌘⇧N`).
    public func openNewWindow() {
        let store = WindowTabStore(settings: KadmosSettings.shared, createInitialTab: true)
        store.pendingBringToFront = true
        pendingWindowStores.append(store)
        if let openNewWindowAction {
            openNewWindowAction()
        } else {
            registerWindowStore(store)
        }
    }

    /// Moves `tab` out of `sourceStore` into a newly spawned window.
    public func moveTabToNewWindow(_ tab: DocumentTab, from sourceStore: WindowTabStore) {
        guard let detached = sourceStore.detachTabForNewWindow(tab) else { return }
        let newStore = WindowTabStore(settings: KadmosSettings.shared, createInitialTab: false)
        newStore.insertRestoredTab(detached, select: true)
        pendingWindowStores.append(newStore)
        openNewWindowAction?()
        scheduleSessionPersist()
    }

    /// Presents the macOS Powerbox Open panel (`⌘O`).
    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Dosya Aç"

        guard panel.runModal() == .OK else { return }
        openFilesFromFinderOrSystem(panel.urls)
    }

    /// Opens files delivered by Finder, Open panel, or Drag & Drop according to `openFilesTarget`.
    public func openFilesFromFinderOrSystem(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        hasAttemptedInitialRestore = true
        activateApplication()

        switch KadmosSettings.shared.openFilesTarget {
        case .newTab:
            let targetStore = ensureTargetWindowStore()
            for url in urls {
                targetStore.openFile(url: url)
            }
            bringWindowToFront(targetStore)

        case .newWindow:
            if let existing = activeWindowStore,
               existing.tabs.count == 1,
               existing.tabs[0].isEmptyPristineUntitled {
                existing.openFile(url: urls[0])
                bringWindowToFront(existing)
                for extraURL in urls.dropFirst() {
                    openURLInDedicatedNewWindow(extraURL)
                }
            } else {
                for url in urls {
                    openURLInDedicatedNewWindow(url)
                }
            }
        }
    }

    private func openURLInDedicatedNewWindow(_ url: URL) {
        activateApplication()
        let store = WindowTabStore(settings: KadmosSettings.shared, createInitialTab: false)
        store.openFile(url: url)
        if store.tabs.isEmpty {
            _ = store.addNewTab(select: true)
        }
        store.pendingBringToFront = true
        pendingWindowStores.append(store)
        openNewWindowAction?()
    }

    /// Opens a recent file entry using its stored security-scoped bookmark (`SECURITY.md` §2.4).
    public func openRecentEntry(_ entry: RecentFileEntry) {
        guard let resolvedURL = BookmarkStore.shared.resolveAndAccess(entry: entry) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\"\(entry.displayName)\" açılamadı"
            alert.informativeText = "Dosya yer imi artık geçerli değil veya dosya taşınmış olabilir."
            alert.runModal()
            BookmarkStore.shared.removeRecentFile(id: entry.id)
            return
        }

        let targetStore = ensureTargetWindowStore()
        targetStore.openFile(url: resolvedURL, asEncoding: nil, bookmarkData: entry.bookmarkData)
        bringWindowToFront(targetStore)
    }

    /// Handles validated `kadmos://` external URLs with strict user confirmation (`SECURITY.md` §5).
    public func handleIncomingURL(_ url: URL) {
        switch URLRouteValidator.validate(url) {
        case .failure(let error):
            KadmosLogger.warning(.security, message: "Blocked invalid kadmos:// URL route (\(String(describing: error)))")

        case .success(.newDocument(let directory)):
            presentNewDocumentSavePanel(preselectedDirectory: directory)

        case .success(.openRequest(let fileURL)):
            guard let fileURL else {
                presentOpenPanel()
                return
            }
            confirmAndOpenRouteFile(fileURL)
        }
    }

    /// Presents a Powerbox `NSSavePanel` pre-directed to the right-clicked folder; never writes without consent (`SECURITY.md` §5).
    private func presentNewDocumentSavePanel(preselectedDirectory: URL?) {
        activateApplication()

        let panel = NSSavePanel()
        panel.title = "Yeni Kadmos Belgesi Oluştur"
        panel.prompt = "Oluştur ve Aç"
        panel.nameFieldStringValue = "Yeni Belge.txt"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let preselectedDirectory {
            panel.directoryURL = preselectedDirectory
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try DocumentSecurity.atomicSave(data: Data(), to: destinationURL)
            let store = ensureTargetWindowStore()
            store.openFile(url: destinationURL)
            bringWindowToFront(store)
        } catch {
            let store = ensureTargetWindowStore()
            store.alertMessage = KadmosAlert(
                title: "Yeni Belge Oluşturulamadı",
                message: error.localizedDescription
            )
        }
    }

    /// Requires explicit user confirmation before opening a path passed via `kadmos://open-request`.
    private func confirmAndOpenRouteFile(_ fileURL: URL) {
        activateApplication()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\"\(fileURL.lastPathComponent)\" dosyasını Kadmos ile açmak istiyor musunuz?"
        alert.informativeText = "Harici bir bağlantı bu dosyayı açma isteği gönderdi:\n\(fileURL.path)"
        alert.addButton(withTitle: "Dosyayı Aç")
        let cancelBtn = alert.addButton(withTitle: "İptal")
        cancelBtn.keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        // In App Sandbox, Powerbox permission may not yet exist for an arbitrary URL-scheme path.
        // Try opening directly if already permitted (e.g. matching recent bookmark), else guide user via NSOpenPanel.
        if let existingRecent = BookmarkStore.shared.recentFiles.first(where: { $0.path == fileURL.path }) {
            openRecentEntry(existingRecent)
            return
        }

        if FileManager.default.isReadableFile(atPath: fileURL.path) {
            let store = ensureTargetWindowStore()
            store.openFile(url: fileURL)
            bringWindowToFront(store)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Dosya Erişimini Onayla"
        panel.prompt = "Aç"
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let selected = panel.url {
            let store = ensureTargetWindowStore()
            store.openFile(url: selected)
            bringWindowToFront(store)
        }
    }

    // MARK: - Session Persistence & Restoration

    public func scheduleSessionPersist() {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.persistSessionNow()
        }
    }

    public func persistSessionNow() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil

        guard KadmosSettings.shared.startupBehavior == .continuePreviousSession else {
            return
        }

        let allTabs = windows.flatMap(\.tabs)
        var snapshots: [SessionTabSnapshot] = []
        snapshots.reserveCapacity(allTabs.count)

        for tab in allTabs {
            // Do not store streaming (>1 GB) buffer chunks in drafts.
            var draftFilename: String? = nil
            if !tab.isReadOnlyLargeMode && (tab.isDirty || (tab.fileURL == nil && (!tab.text.isEmpty || tab.customFilename != nil))) {
                draftFilename = try? sessionVault.saveDraft(text: tab.text, forTabID: tab.id)
            }

            let cursorLoc = tab.selectedRange.location == NSNotFound ? 0 : tab.selectedRange.location
            let snap = SessionTabSnapshot(
                id: tab.id,
                filePath: tab.fileURL?.path,
                bookmarkData: tab.bookmarkData,
                untitledNumber: tab.untitledNumber,
                encoding: tab.encoding,
                lineEnding: tab.lineEnding,
                isDirty: tab.isDirty,
                cursorLocation: cursorLoc,
                zoomPercent: tab.zoomPercent,
                draftFilename: draftFilename,
                customFilename: tab.customFilename
            )
            snapshots.append(snap)
        }

        let activeID = activeWindowStore?.activeTab?.id ?? allTabs.first?.id
        let snapshot = SessionSnapshot(activeTabID: activeID, tabs: snapshots)
        do {
            try sessionVault.saveSnapshot(snapshot)
        } catch {
            KadmosLogger.error(.session, message: "Failed to persist session snapshot", error: error)
        }
    }

    /// Handles `NSApplicationDelegate.applicationShouldTerminate` cleanly according to `startupBehavior`.
    public func handleApplicationShouldTerminate() -> NSApplication.TerminateReply {
        if KadmosSettings.shared.startupBehavior == .continuePreviousSession {
            persistSessionNow()
            return .terminateNow
        }

        for store in windows {
            if !store.confirmCloseAllTabsForWindowClose() {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    /// Removes all persisted session metadata and unsaved draft files (`SECURITY.md` §6).
    public func clearAllSessionData() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        do {
            try sessionVault.clearAll()
        } catch {
            KadmosLogger.error(.session, message: "Failed to clear SessionVault", error: error)
        }
    }

    // MARK: - Private Helpers

    private func ensureTargetWindowStore() -> WindowTabStore {
        if let active = activeWindowStore {
            return active
        }
        let fresh = WindowTabStore(settings: KadmosSettings.shared, createInitialTab: true)
        fresh.pendingBringToFront = true
        pendingWindowStores.append(fresh)
        openNewWindowAction?()
        if !windows.contains(where: { $0.windowID == fresh.windowID }) {
            registerWindowStore(fresh)
        }
        return fresh
    }

    private func restoreSessionIntoStore() -> WindowTabStore? {
        guard let snapshot = try? sessionVault.loadSnapshot(), !snapshot.tabs.isEmpty else {
            return nil
        }

        let store = WindowTabStore(settings: KadmosSettings.shared, createInitialTab: false)
        for item in snapshot.tabs {
            if let restored = buildTabFromSnapshot(item) {
                store.insertRestoredTab(restored, select: item.id == snapshot.activeTabID)
            }
        }

        guard !store.tabs.isEmpty else { return nil }
        if let activeID = snapshot.activeTabID,
           store.tabs.contains(where: { $0.id == activeID }) {
            store.activeTabID = activeID
        } else {
            store.activeTabID = store.tabs.first?.id
        }
        return store
    }

    private func buildTabFromSnapshot(_ snap: SessionTabSnapshot) -> DocumentTab? {
        // Case 1: Draft buffer exists (unsaved untitled or dirty modified file).
        if let draftName = snap.draftFilename,
           let draftText = try? sessionVault.loadDraft(filename: draftName) {
            let fileURL = snap.filePath.map { URL(fileURLWithPath: $0) }
            let clampedCursor = max(0, min(snap.cursorLocation, (draftText as NSString).length))
            let tab = DocumentTab(
                id: snap.id,
                fileURL: fileURL,
                untitledNumber: snap.untitledNumber,
                customFilename: snap.customFilename,
                text: draftText,
                encoding: snap.encoding,
                lineEnding: snap.lineEnding,
                isDirty: snap.isDirty,
                zoomPercent: snap.zoomPercent,
                selectedRange: NSRange(location: clampedCursor, length: 0),
                bookmarkData: snap.bookmarkData
            )
            tab.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
            return tab
        }

        // Case 2: Clean file-backed tab — reload via security-scoped bookmark (`SECURITY.md` §2.4).
        if let bookmarkData = snap.bookmarkData {
            do {
                let (payload, decoded, lineEnding): (OpenedDocumentPayload, DecodedTextResult?, KadmosLineEnding) =
                    try BookmarkStore.shared.withScopedAccess(to: bookmarkData) { scopedURL in
                        let overrideEnc: KadmosTextEncoding? = snap.encoding != .utf8 ? snap.encoding : nil
                        let payload = try DocumentSecurity.openDocument(at: scopedURL, overrideEncoding: overrideEnc)
                        return (payload, payload.decoded, payload.detectedLineEnding)
                    }

                if case .streamingReadOnly = payload.tier {
                    let tab = DocumentTab(
                        id: snap.id,
                        fileURL: payload.canonicalURL,
                        untitledNumber: nil,
                        text: "",
                        encoding: .utf8,
                        lineEnding: .lf,
                        isDirty: false,
                        zoomPercent: snap.zoomPercent,
                        largeFileTier: payload.tier,
                        streamingReader: payload.streamingReader,
                        bookmarkData: bookmarkData
                    )
                    return tab
                }

                if let decoded {
                    let clampedCursor = max(0, min(snap.cursorLocation, (decoded.text as NSString).length))
                    let tab = DocumentTab(
                        id: snap.id,
                        fileURL: payload.canonicalURL,
                        untitledNumber: nil,
                        text: decoded.text,
                        encoding: decoded.encoding,
                        lineEnding: lineEnding,
                        isDirty: false,
                        zoomPercent: snap.zoomPercent,
                        selectedRange: NSRange(location: clampedCursor, length: 0),
                        largeFileTier: payload.tier,
                        hasEncodingWarning: decoded.hadInvalidSequences,
                        invalidEncodingCount: decoded.invalidSequenceCount,
                        bookmarkData: bookmarkData
                    )
                    tab.refreshTrojanFindings(enabled: KadmosSettings.shared.highlightTrojanChars)
                    return tab
                }
            } catch {
                KadmosLogger.error(.session, message: "Skipped restoring unreachable file tab", error: error)
                return nil
            }
        }

        // Case 3: Empty untitled tab preserved across session.
        if snap.filePath == nil {
            return DocumentTab(
                id: snap.id,
                fileURL: nil,
                untitledNumber: snap.untitledNumber ?? 1,
                text: "",
                encoding: snap.encoding,
                lineEnding: snap.lineEnding,
                isDirty: false,
                zoomPercent: snap.zoomPercent
            )
        }

        return nil
    }
}

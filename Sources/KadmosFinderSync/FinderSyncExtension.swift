import Cocoa
import FinderSync
import KadmosCore

@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
    override init() {
        super.init()

        // Monitor local root so Finder invokes menu(for:) on Desktop, home folders, and mounted volumes.
        // The extension never reads/writes file contents here; it delegates exclusively via kadmos:// URL or NSWorkspace open.
        let controller = FIFinderSyncController.default()
        controller.directoryURLs = [URL(fileURLWithPath: "/")]
        KadmosLogger.info(.finder, message: "KadmosFinderSync initialized")
    }

    override func beginObservingDirectory(at url: URL) {
        KadmosLogger.infoPath(.finder, message: "Observing directory", path: url.path)
    }

    override func endObservingDirectory(at url: URL) {
        KadmosLogger.infoPath(.finder, message: "Ended observing directory", path: url.path)
    }

    override func requestBadgeIdentifier(for url: URL) {
        // Kadmos does not overlay status badges onto Finder items.
    }

    // MARK: - Toolbar Button

    override var toolbarItemName: String {
        "Kadmos"
    }

    override var toolbarItemToolTip: String {
        "Yeni Kadmos Belgesi Oluştur"
    }

    override var toolbarItemImage: NSImage {
        let img = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Yeni Kadmos Belgesi")
            ?? NSImage(named: NSImage.addTemplateName)
            ?? NSImage()
        img.isTemplate = true
        return img
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForContainer, .toolbarItemMenu:
            let menu = NSMenu(title: "Kadmos")
            menu.addItem(makeNewDocumentMenuItem())
            return menu

        case .contextualMenuForItems:
            let menu = NSMenu(title: "Kadmos")
            menu.addItem(makeNewDocumentMenuItem())

            if let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty {
                let openItem = NSMenuItem(
                    title: "Kadmos ile Aç",
                    action: #selector(openSelectedInKadmos(_:)),
                    keyEquivalent: ""
                )
                openItem.target = self
                if let symbol = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Kadmos ile Aç") {
                    symbol.isTemplate = true
                    openItem.image = symbol
                }
                menu.addItem(openItem)
            }
            return menu

        case .contextualMenuForSidebar:
            return nil

        @unknown default:
            return nil
        }
    }

    private func makeNewDocumentMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Yeni Kadmos Belgesi",
            action: #selector(createNewDocument(_:)),
            keyEquivalent: ""
        )
        item.target = self
        if let symbol = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Yeni Kadmos Belgesi") {
            symbol.isTemplate = true
            item.image = symbol
        }
        return item
    }

    // MARK: - Actions

    @objc private func createNewDocument(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        let directoryURL = resolveTargetDirectory(controller: controller)

        var components = URLComponents()
        components.scheme = "kadmos"
        components.host = "new-document"
        if let directoryURL {
            components.queryItems = [URLQueryItem(name: "dir", value: directoryURL.path)]
        }

        guard let routeURL = components.url else {
            KadmosLogger.error(.finder, message: "Failed to build kadmos:// route URL")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(routeURL, configuration: config) { _, error in
            if let error {
                KadmosLogger.error(.finder, message: "Failed to open Kadmos host app", error: error)
            }
        }
    }

    @objc private func openSelectedInKadmos(_ sender: AnyObject?) {
        guard let selected = FIFinderSyncController.default().selectedItemURLs(), !selected.isEmpty else {
            return
        }

        // Host bundle is 3 levels above Contents/PlugIns/KadmosFinderSync.appex
        let hostAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(selected, withApplicationAt: hostAppURL, configuration: config) { _, error in
            if let error {
                KadmosLogger.error(.finder, message: "Failed to open selected items in Kadmos", error: error)
            }
        }
    }

    private func resolveTargetDirectory(controller: FIFinderSyncController) -> URL? {
        if let selected = controller.selectedItemURLs(), selected.count == 1, let first = selected.first {
            if first.hasDirectoryPath {
                return first
            }
            if let values = try? first.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                return first
            }
        }
        if let targeted = controller.targetedURL() {
            return targeted
        }
        if let first = controller.selectedItemURLs()?.first {
            return first.deletingLastPathComponent()
        }
        return nil
    }
}

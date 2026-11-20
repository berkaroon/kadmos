import AppKit
import KadmosCore
import SwiftUI

/// Root view hosted by each editor `WindowGroup` scene, owning a claimed/restored `WindowTabStore`.
private struct EditorWindowRoot: View {
    @State private var store: WindowTabStore?
    @State private var settings = KadmosSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let store {
                EditorContentView(store: store, settings: settings)
            } else {
                Color.clear
                    .frame(minWidth: 980, minHeight: 680)
            }
        }
        .onAppear {
            if store == nil {
                store = AppController.shared.claimOrCreateWindowStore()
            }
            AppController.shared.registerOpenWindowHandler {
                openWindow(id: "editor")
            }
        }
    }
}

/// AppKit lifecycle delegate bridging Finder open-file requests, `kadmos://` URLs, and termination.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        KadmosSettings.shared.applyAppearance()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        var fileURLs: [URL] = []
        for url in urls {
            if url.isFileURL {
                fileURLs.append(url)
            } else if url.scheme?.lowercased() == "kadmos" {
                AppController.shared.handleIncomingURL(url)
            }
        }
        if !fileURLs.isEmpty {
            AppController.shared.openFilesFromFinderOrSystem(fileURLs)
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppController.shared.handleApplicationShouldTerminate()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppController.shared.openNewWindow()
        }
        return true
    }
}

@main
public struct KadmosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        WindowGroup("Kadmos", id: "editor") {
            EditorWindowRoot()
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: Set<String>())
        .defaultSize(width: 980, height: 680)
        .commands {
            KadmosCommands()
        }

        Settings {
            SettingsView()
        }

        Window("Kadmos Hakkında", id: "about") {
            AboutKadmosView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Complete Native macOS Menu Bar Commands

private struct KadmosCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    private var controller: AppController { AppController.shared }
    private var activeStore: WindowTabStore? { controller.activeWindowStore }
    private var activeTab: DocumentTab? { activeStore?.activeTab }

    private static var f5KeyEquivalent: KeyEquivalent {
        if let scalar = UnicodeScalar(NSF5FunctionKey) {
            return KeyEquivalent(Character(scalar))
        }
        return KeyEquivalent("t")
    }

    var body: some Commands {
        // App Info
        CommandGroup(replacing: .appInfo) {
            Button("Kadmos Hakkında") {
                openWindow(id: "about")
            }
        }

        // File -> New / Open / Recent / Close
        CommandGroup(replacing: .newItem) {
            Button("Yeni Sekme") {
                _ = activeStore?.addNewTab()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Yeni Pencere") {
                controller.openNewWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Aç…") {
                controller.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Son Açılanlar") {
                let recents = BookmarkStore.shared.recentFiles
                if recents.isEmpty {
                    Text("Son açılan dosya yok")
                } else {
                    ForEach(recents) { entry in
                        Button(entry.displayName) {
                            controller.openRecentEntry(entry)
                        }
                    }
                    Divider()
                    Button("Menüyü Temizle") {
                        BookmarkStore.shared.clearRecentFiles()
                    }
                }
            }

            Divider()

            Button("Sekmeyi Kapat") {
                activeStore?.closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(activeStore == nil)

            Button("Pencereyi Kapat") {
                activeStore?.requestWindowClose()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(activeStore?.hostWindow == nil)

            Button("Kapatılan Sekmeyi Yeniden Aç") {
                activeStore?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(activeStore?.closedTabSnapshots.isEmpty ?? true)
        }

        // File -> Save / Reopen with Encoding
        CommandGroup(replacing: .saveItem) {
            Button("Kaydet") {
                activeStore?.saveActiveTab()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(activeTab == nil || (activeTab?.isReadOnlyLargeMode ?? true))

            Button("Farklı Kaydet…") {
                activeStore?.saveActiveTabAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(activeTab == nil || (activeTab?.isReadOnlyLargeMode ?? true))

            Button("Tümünü Kaydet") {
                activeStore?.saveAllTabs()
            }
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(!(activeStore?.tabs.contains(where: { $0.isDirty && !$0.isReadOnlyLargeMode }) ?? false))

            Divider()

            Menu("Kodlama ile Yeniden Aç") {
                ForEach(KadmosTextEncoding.allCases) { encoding in
                    Button(encoding.displayName) {
                        activeStore?.reopenActiveTab(withEncoding: encoding)
                    }
                }
            }
            .disabled(activeTab?.fileURL == nil || (activeTab?.isReadOnlyLargeMode ?? true))
        }

        // File -> Page Setup / Print
        CommandGroup(replacing: .printItem) {
            Button("Sayfa Yapısı…") {
                activeStore?.dispatchEditorAction(.pageSetup)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(activeTab == nil)

            Button("Yazdır…") {
                activeStore?.dispatchEditorAction(.printDocument)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(activeTab == nil)
        }

        // Edit -> Find / Replace / Go To Line / Insert Time/Date
        CommandGroup(after: .undoRedo) {
            Divider()

            Button("Bul…") {
                activeStore?.showFindBar(replaceExpanded: false)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(activeTab == nil)

            Button("Değiştir…") {
                activeStore?.showFindBar(replaceExpanded: true)
            }
            .keyboardShortcut("f", modifiers: [.option, .command])
            .disabled(activeTab == nil || (activeTab?.isReadOnlyLargeMode ?? true))

            Button("Sonrakini Bul") {
                activeStore?.findNext()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(activeTab == nil)

            Button("Öncekini Bul") {
                activeStore?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(activeTab == nil)

            Button("Satıra Git…") {
                activeStore?.isGoToLinePresented = true
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(activeTab == nil)

            Divider()

            Button("Saat/Tarih Ekle") {
                activeStore?.insertTimeDate()
            }
            .keyboardShortcut(Self.f5KeyEquivalent, modifiers: [])
            .disabled(activeTab == nil || (activeTab?.isReadOnlyLargeMode ?? true))
        }

        // View Menu ("Görünüm")
        CommandMenu("Görünüm") {
            Button("Yakınlaştır") {
                activeStore?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(activeTab == nil)

            Button("Uzaklaştır") {
                activeStore?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(activeTab == nil)

            Button("Varsayılan Yakınlaştırma (%100)") {
                activeStore?.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(activeTab == nil)

            Divider()

            Button(activeStore?.wordWrap == true ? "Sözcük Kaydırma ✓" : "Sözcük Kaydırma") {
                activeStore?.wordWrap.toggle()
            }
            .keyboardShortcut("z", modifiers: .option)
            .disabled(activeStore == nil)

            Button(activeStore?.showStatusBar == true ? "Durum Çubuğu ✓" : "Durum Çubuğu") {
                activeStore?.showStatusBar.toggle()
            }
            .disabled(activeStore == nil)

            Button(
                KadmosSettings.shared.highlightTrojanChars
                    ? "Trojan Source / Görünmez Karakterleri Vurgula ✓"
                    : "Trojan Source / Görünmez Karakterleri Vurgula"
            ) {
                KadmosSettings.shared.highlightTrojanChars.toggle()
            }

            Divider()

            Menu("Satır Sonu Biçimi") {
                ForEach(KadmosLineEnding.allCases) { eol in
                    Button {
                        activeStore?.convertLineEnding(eol)
                    } label: {
                        if activeTab?.lineEnding == eol {
                            Label(eol.displayName, systemImage: "checkmark")
                        } else {
                            Text(eol.displayName)
                        }
                    }
                }
            }
            .disabled(activeTab == nil || (activeTab?.isReadOnlyLargeMode ?? true))

            Menu("Kodlama Biçimi") {
                ForEach(KadmosTextEncoding.allCases) { enc in
                    Button {
                        activeStore?.convertEncoding(enc)
                    } label: {
                        if activeTab?.encoding == enc {
                            Label(enc.displayName, systemImage: "checkmark")
                        } else {
                            Text(enc.displayName)
                        }
                    }
                }
            }
            .disabled(activeTab == nil || (activeTab?.isReadOnlyLargeMode ?? true))
        }

        // Tab Menu ("Sekme")
        CommandMenu("Sekme") {
            Button("Sonraki Sekme") {
                activeStore?.selectNextTab()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled((activeStore?.tabs.count ?? 0) <= 1)

            Button("Önceki Sekme") {
                activeStore?.selectPreviousTab()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled((activeStore?.tabs.count ?? 0) <= 1)

            Divider()

            ForEach(1...9, id: \.self) { idx in
                Button("Sekme \(idx)") {
                    activeStore?.selectTab(atOneBasedIndex: idx)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
                .disabled((activeStore?.tabs.count ?? 0) < idx && !(idx == 9 && (activeStore?.tabs.count ?? 0) > 0))
            }

            Divider()

            Button("Sekmeyi Yeni Pencereye Taşı") {
                if let store = activeStore, let tab = activeTab {
                    controller.moveTabToNewWindow(tab, from: store)
                }
            }
            .disabled((activeStore?.tabs.count ?? 0) <= 1 || activeTab == nil)
        }
    }
}

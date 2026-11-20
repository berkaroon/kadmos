import KadmosCore
import SwiftUI
import UniformTypeIdentifiers

/// Main document window view composing the Liquid Glass tab strip, warning banners,
/// native AppKit plain-text editor (or >1 GB streaming viewer), floating Find/Replace HUD, and status bar.
public struct EditorContentView: View {
    @Bindable public var store: WindowTabStore
    public let settings: KadmosSettings

    public init(store: WindowTabStore, settings: KadmosSettings = .shared) {
        self.store = store
        self.settings = settings
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let tab = store.activeTab {
                    let topClearance = computeTopClearance(for: tab)
                    Group {
                        if tab.isReadOnlyLargeMode {
                            StreamingLargeFileView(
                                tab: tab,
                                store: store,
                                settings: settings,
                                topContentInset: topClearance
                            )
                        } else {
                            KadmosEditorRepresentable(
                                tab: tab,
                                store: store,
                                settings: settings,
                                topContentInset: topClearance
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                } else {
                    Color(nsColor: .textBackgroundColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .top)
                }

                VStack(spacing: 0) {
                    GlassTabBarView(store: store, isFullScreen: store.isFullScreen)

                    if let tab = store.activeTab {
                        warningBanners(for: tab)
                    }

                    if store.isFindBarVisible {
                        HStack {
                            Spacer(minLength: 0)
                            FindReplaceBarView(store: store)
                                .padding(.top, 8)
                                .padding(.trailing, 14)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let tab = store.activeTab, store.showStatusBar {
                StatusBarView(tab: tab, store: store, settings: settings)
            }
        }
        .sheet(isPresented: $store.isGoToLinePresented) {
            GoToLineSheetView(store: store)
        }
        .alert(item: $store.alertMessage) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("Tamam"))
            )
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDroppedFiles(providers)
        }
        .onChange(of: settings.highlightTrojanChars) { _, enabled in
            for tab in store.tabs {
                tab.refreshTrojanFindings(enabled: enabled)
            }
        }
    }

    private func computeTopClearance(for tab: DocumentTab) -> CGFloat {
        var clearance: CGFloat = GlassTabBarView.barHeight + 4
        if settings.highlightTrojanChars && !tab.trojanFindings.isEmpty && !tab.isTrojanBannerDismissed {
            clearance += 34
        }
        if tab.hasEncodingWarning && !tab.isEncodingBannerDismissed {
            clearance += 34
        }
        if tab.isLimitedLargeMode && !tab.isLargeFileBannerDismissed {
            clearance += 34
        }
        return clearance
    }

    @ViewBuilder
    private func warningBanners(for tab: DocumentTab) -> some View {
        if settings.highlightTrojanChars && !tab.trojanFindings.isEmpty && !tab.isTrojanBannerDismissed {
            bannerRow(
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                message: "Güvenlik Uyarısı: Bu belgede \(tab.trojanFindings.count) adet görünmez veya çift yönlü (Trojan Source) kontrol karakteri tespit edildi."
            ) {
                if let first = tab.trojanFindings.first {
                    Button("İlkine Git") {
                        tab.selectedRange = first.utf16Range
                        store.dispatchEditorAction(.scrollToRange(first.utf16Range))
                    }
                    .controlSize(.small)
                }
                Button {
                    tab.isTrojanBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }

        if tab.hasEncodingWarning && !tab.isEncodingBannerDismissed {
            bannerRow(
                icon: "exclamationmark.triangle.fill",
                tint: .yellow,
                message: "Kodlama Uyarısı: Dosyada geçersiz bayt dizileri bulundu ve U+FFFD değiştirme karakteri ile açıldı."
            ) {
                if tab.fileURL != nil && !tab.isReadOnlyLargeMode {
                    Menu("Kodlama ile Yeniden Aç") {
                        ForEach(KadmosTextEncoding.allCases) { enc in
                            Button(enc.displayName) {
                                store.reopenActiveTab(withEncoding: enc)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                Button {
                    tab.isEncodingBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }

        if tab.isLimitedLargeMode && !tab.isLargeFileBannerDismissed {
            bannerRow(
                icon: "info.circle.fill",
                tint: .blue,
                message: "Büyük Dosya (> 50 MB): Performans ve bellek güvenliği için canlı yazım denetimi devre dışı bırakıldı."
            ) {
                Button {
                    tab.isLargeFileBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bannerRow<Actions: View>(
        icon: String,
        tint: Color,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11.5))
                .lineLimit(2)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(tint.opacity(0.11))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else {
                    resolvedURL = nil
                }

                if let resolvedURL {
                    Task { @MainActor in
                        AppController.shared.openFilesFromFinderOrSystem([resolvedURL])
                    }
                }
            }
        }
        return accepted
    }
}

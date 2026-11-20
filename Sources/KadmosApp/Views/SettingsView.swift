import AppKit
import KadmosCore
import SwiftUI

/// Native macOS Settings window organized into grouped sections matching system conventions.
public struct SettingsView: View {
    @State private var settings = KadmosSettings.shared
    @State private var bookmarks = BookmarkStore.shared

    @State private var extensionsInput: String = ""
    @State private var showClearSessionConfirm: Bool = false
    @State private var showClearRecentConfirm: Bool = false

    public init() {}

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("Genel", systemImage: "gearshape")
                }

            fontTab
                .tabItem {
                    Label("Yazı Tipi", systemImage: "textformat")
                }

            spellingTab
                .tabItem {
                    Label("Yazım Denetimi", systemImage: "textformat.abc")
                }

            finderTab
                .tabItem {
                    Label("Finder", systemImage: "folder.badge.plus")
                }

            securityTab
                .tabItem {
                    Label("Güvenlik ve Gizlilik", systemImage: "lock.shield")
                }
        }
        .frame(width: 560, height: 420)
        .onAppear {
            extensionsInput = settings.spellCheckIgnoredExtensions.joined(separator: ", ")
        }
    }

    // MARK: - Genel

    private var generalTab: some View {
        Form {
            Section("Görünüm ve Oturum") {
                Picker("Tema:", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }

                Picker("Başlangıçta:", selection: $settings.startupBehavior) {
                    ForEach(StartupBehavior.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }

                Picker("Dosyaları Aç:", selection: $settings.openFilesTarget) {
                    ForEach(OpenFilesTarget.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
            }

            Section("Yeni Pencere Varsayılanları") {
                Toggle("Sözcük Kaydırma", isOn: $settings.wordWrap)
                Toggle("Durum Çubuğunu Göster", isOn: $settings.showStatusBar)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Yazı Tipi

    private var fontTab: some View {
        let styles = settings.availableStyles(forFamily: settings.fontFamily)
        let previewNSFont = settings.resolvedNSFont(zoomPercent: 100)

        return Form {
            Section("Yazı Tipi Seçimi") {
                Picker("Yazı Tipi Ailesi:", selection: $settings.fontFamily) {
                    ForEach(settings.availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .onChange(of: settings.fontFamily) { _, newFamily in
                    let available = settings.availableStyles(forFamily: newFamily)
                    if !available.contains(settings.fontStyle) {
                        settings.fontStyle = available.first ?? "Regular"
                    }
                }

                Picker("Stil:", selection: $settings.fontStyle) {
                    ForEach(styles, id: \.self) { style in
                        Text(style).tag(style)
                    }
                }

                HStack {
                    Text("Boyut:")
                    Slider(
                        value: $settings.fontSize,
                        in: KadmosSettings.minFontSize...KadmosSettings.maxFontSize,
                        step: 1
                    )
                    Stepper(
                        "\(Int(settings.fontSize)) pt",
                        value: $settings.fontSize,
                        in: KadmosSettings.minFontSize...KadmosSettings.maxFontSize,
                        step: 1
                    )
                    .monospacedDigit()
                    .frame(width: 96)
                }
            }

            Section("Canlı Önizleme") {
                Text("Hızlı kahverengi tilki tembel köpeğin üzerinden atlar.\n0123456789 {} [] () <= => != ğüşıöç ĞÜŞİÖÇ")
                    .font(Font(previewNSFont))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Yazım Denetimi

    private var spellingTab: some View {
        Form {
            Section("Düzenleyici Davranışı") {
                Toggle("Yazım denetimini etkinleştir", isOn: $settings.spellCheckEnabled)
                Toggle("Otomatik düzeltmeyi etkinleştir", isOn: $settings.autocorrectEnabled)
                    .disabled(!settings.spellCheckEnabled)
            }

            Section("Yoksayılan Dosya Uzantıları") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bu uzantılara sahip kaynak kod veya yapılandırma dosyalarında yazım denetimi otomatik olarak devre dışı bırakılır (virgülle ayırın):")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $extensionsInput)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 82)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                        .onChange(of: extensionsInput) { _, newValue in
                            let parts = newValue
                                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                                .map(String.init)
                            settings.spellCheckIgnoredExtensions = parts
                        }

                    HStack {
                        Spacer()
                        Button("Varsayılanlara Sıfırla") {
                            settings.resetIgnoredSpellCheckExtensions()
                            extensionsInput = settings.spellCheckIgnoredExtensions.joined(separator: ", ")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Finder

    private var finderTab: some View {
        Form {
            Section("Kadmos Finder Genişletmesi") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("KadmosFinderSync, Masaüstü veya herhangi bir Finder klasöründe sağ tıkladığınızda \"Yeni Kadmos Belgesi\" ve \"Kadmos ile Aç\" menü öğelerini sunar.")
                        .font(.callout)

                    Text("Kullanım: Sistem Ayarları → Gizlilik ve Güvenlik / Genişletmeler → Finder Genişletmeleri bölümünden KadmosFinderSync seçeneğini etkinleştirin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button("Finder Genişletmeleri Ayarlarını Aç") {
                            openExtensionsSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Güvenlik ve Gizlilik

    private var securityTab: some View {
        Form {
            Section("Görünmez Karakter Koruması") {
                Toggle("Trojan Source / Gizli Karakterleri Vurgula", isOn: $settings.highlightTrojanChars)
                Text("Çift yönlü (bidi) kontrol karakterlerini, sıfır genişlikli karakterleri ve gizli işaretçileri görünür rozetlerle işaretler.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Büyük Dosya Bellek Sınırları") {
                LabeledContent("Sınırlı Mod Eşiği:") {
                    Text("50 MB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Salt-Okunur Akış Modu Eşiği:") {
                    Text("1 GB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Section("Yerel Veri ve Oturum Saklama") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Oturum ve Taslak Konumu (0600 yalnızca kullanıcı izni):")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(SessionVault.defaultBaseDirectory().path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("Son Açılanları Temizle (\(bookmarks.recentFiles.count))") {
                        showClearRecentConfirm = true
                    }
                    .disabled(bookmarks.recentFiles.isEmpty)

                    Spacer()

                    Button("Oturum ve Taslak Verilerini Sil", role: .destructive) {
                        showClearSessionConfirm = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Son Açılanlar Temizlensin mi?", isPresented: $showClearRecentConfirm) {
            Button("İptal", role: .cancel) {}
            Button("Temizle", role: .destructive) {
                bookmarks.clearRecentFiles()
            }
        } message: {
            Text("Tüm son açılan dosya kayıtları ve güvenlik kapsamlı yer imleri silinecektir.")
        }
        .alert("Oturum ve Taslak Verileri Silinsin mi?", isPresented: $showClearSessionConfirm) {
            Button("İptal", role: .cancel) {}
            Button("Sil", role: .destructive) {
                AppController.shared.clearAllSessionData()
            }
        } message: {
            Text("Kaydedilmiş oturum meta verileri ve taslak dosyaları kalıcı olarak silinecektir.")
        }
    }

    private func openExtensionsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

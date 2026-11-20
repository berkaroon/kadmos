import KadmosCore
import SwiftUI

/// Compact `24pt` bottom status strip with Go-To-Line trigger, document stats,
/// security/encoding indicators, and zoom/EOL/encoding menus.
public struct StatusBarView: View {
    public let tab: DocumentTab
    public let store: WindowTabStore
    public let settings: KadmosSettings

    @State private var trojanJumpIndex: Int = 0

    public init(tab: DocumentTab, store: WindowTabStore, settings: KadmosSettings) {
        self.tab = tab
        self.store = store
        self.settings = settings
    }

    public var body: some View {
        let stats = tab.stats
        let pos = tab.cursorPosition

        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                Button {
                    store.isGoToLinePresented = true
                } label: {
                    Text("St \(pos.line), Süt \(pos.column)")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Satıra Git (⌘L)")

                separatorDot

                Text(characterWordSummary(stats: stats))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if settings.highlightTrojanChars && !tab.trojanFindings.isEmpty {
                    Button {
                        jumpToNextTrojanFinding()
                    } label: {
                        Label("\(tab.trojanFindings.count) gizli karakter", systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("Görünmez / çift yönlü kontrol karakteri tespit edildi — konuma gitmek için tıklayın")
                }

                if tab.hasEncodingWarning {
                    Label(
                        tab.invalidEncodingCount > 0 ? "\(tab.invalidEncodingCount) U+FFFD" : "Kodlama uyarısı",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.yellow.opacity(0.14)))
                    .help("Geçersiz bayt dizileri U+FFFD değiştirme karakteriyle açıldı")
                }

                if let tierLabel = largeFileTierLabel {
                    Label(tierLabel, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.blue.opacity(0.14)))
                }

                Spacer(minLength: 8)

                // Trailing pickers
                HStack(spacing: 10) {
                    zoomMenu

                    Divider()
                        .frame(height: 12)

                    lineEndingMenu

                    Divider()
                        .frame(height: 12)

                    encodingMenu
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(.bar)
        }
    }

    private var separatorDot: some View {
        Text("•")
            .foregroundStyle(.tertiary)
    }

    private var largeFileTierLabel: String? {
        switch tab.largeFileTier {
        case .normal:
            return nil
        case .limitedMode:
            return "> 50 MB Sınırlı Mod"
        case .streamingReadOnly:
            return "> 1 GB Salt-Okunur Akış"
        }
    }

    private var zoomMenu: some View {
        Menu {
            Button("Yakınlaştır (⌘+)") { store.zoomIn() }
            Button("Uzaklaştır (⌘-)") { store.zoomOut() }
            Button("Varsayılan (%100)") { store.resetZoom() }

            Divider()

            ForEach([50, 75, 100, 125, 150, 200], id: \.self) { level in
                Button {
                    store.setZoom(level)
                } label: {
                    if tab.zoomPercent == level {
                        Label("%\(level)", systemImage: "checkmark")
                    } else {
                        Text("%\(level)")
                    }
                }
            }
        } label: {
            Text("%\(tab.zoomPercent)")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Yakınlaştırma Düzeyi")
    }

    private var lineEndingMenu: some View {
        Menu {
            ForEach(KadmosLineEnding.allCases) { eol in
                Button {
                    store.convertLineEnding(eol)
                } label: {
                    if tab.lineEnding == eol {
                        Label(eol.displayName, systemImage: "checkmark")
                    } else {
                        Text(eol.displayName)
                    }
                }
            }
        } label: {
            Text(tab.lineEnding.shortStatusName)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tab.isReadOnlyLargeMode)
        .help("Satır Sonu Biçimi")
    }

    private var encodingMenu: some View {
        Menu {
            Menu("Kodlama ile Kaydet (Dönüştür)") {
                ForEach(KadmosTextEncoding.allCases) { enc in
                    Button {
                        store.convertEncoding(enc)
                    } label: {
                        if tab.encoding == enc {
                            Label(enc.displayName, systemImage: "checkmark")
                        } else {
                            Text(enc.displayName)
                        }
                    }
                }
            }
            .disabled(tab.isReadOnlyLargeMode)

            Menu("Kodlama ile Yeniden Aç") {
                ForEach(KadmosTextEncoding.allCases) { enc in
                    Button(enc.displayName) {
                        store.reopenActiveTab(withEncoding: enc)
                    }
                }
            }
            .disabled(tab.fileURL == nil || tab.isReadOnlyLargeMode)
        } label: {
            Text(tab.encoding.shortStatusName)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Karakter Kodlaması")
    }

    private func characterWordSummary(stats: DocumentStats) -> String {
        let formatter = Self.integerFormatter
        let totalChars = formatter.string(from: NSNumber(value: stats.characterCount)) ?? "\(stats.characterCount)"
        let totalWords = formatter.string(from: NSNumber(value: stats.wordCount)) ?? "\(stats.wordCount)"

        if stats.selectedCharacterCount > 0 {
            let selected = formatter.string(from: NSNumber(value: stats.selectedCharacterCount))
                ?? "\(stats.selectedCharacterCount)"
            return "Seçili: \(selected) / \(totalChars) karakter • \(totalWords) kelime"
        }
        return "\(totalChars) karakter • \(totalWords) kelime"
    }

    private func jumpToNextTrojanFinding() {
        guard !tab.trojanFindings.isEmpty else { return }
        let idx = trojanJumpIndex % tab.trojanFindings.count
        trojanJumpIndex = (idx + 1) % tab.trojanFindings.count
        let range = tab.trojanFindings[idx].utf16Range
        tab.selectedRange = range
        store.dispatchEditorAction(.scrollToRange(range))
    }

    private static let integerFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = true
        return nf
    }()
}

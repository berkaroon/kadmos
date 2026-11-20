import KadmosCore
import SwiftUI

/// Bounded, read-only chunk viewer for files exceeding 1 GB (`SECURITY.md` §3.5).
public struct StreamingLargeFileView: View {
    public let tab: DocumentTab
    public let store: WindowTabStore
    public let settings: KadmosSettings
    public let topContentInset: CGFloat

    @State private var jumpPercent: Double = 0
    @State private var isLoadingChunk: Bool = false

    public init(
        tab: DocumentTab,
        store: WindowTabStore,
        settings: KadmosSettings,
        topContentInset: CGFloat = 0
    ) {
        self.tab = tab
        self.store = store
        self.settings = settings
        self.topContentInset = topContentInset
    }

    public var body: some View {
        let totalBytes: Int64 = {
            if case .streamingReadOnly(let bytes) = tab.largeFileTier {
                return bytes
            }
            return tab.streamingReader?.totalBytes ?? 0
        }()

        VStack(spacing: 0) {
            streamingHeaderBar(totalBytes: totalBytes)
                .padding(.top, topContentInset)
            Divider()
            KadmosEditorRepresentable(
                tab: tab,
                store: store,
                settings: settings,
                isReadOnly: true,
                topContentInset: 0
            )
        }
        .task(id: tab.id) {
            if tab.streamingChunkText.isEmpty && tab.streamingReader != nil {
                isLoadingChunk = true
                await store.loadStreamingChunk(for: tab, atOffset: 0)
                updateSliderFromCurrentOffset(totalBytes: totalBytes)
                isLoadingChunk = false
            } else {
                updateSliderFromCurrentOffset(totalBytes: totalBytes)
            }
        }
    }

    private func streamingHeaderBar(totalBytes: Int64) -> some View {
        HStack(spacing: 12) {
            Label("Salt-Okunur Akış Modu (> 1 GB)", systemImage: "lock.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)

            Text(byteRangeSummary(totalBytes: totalBytes))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text("Konum:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(value: $jumpPercent, in: 0...100)
                    .frame(width: 130)
                    .controlSize(.small)

                Text("\(Int(jumpPercent.rounded()))%")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)

                Button("Git") {
                    let targetOffset = Int64(Double(totalBytes) * (jumpPercent / 100.0))
                    loadChunk(atOffset: targetOffset, totalBytes: totalBytes)
                }
                .controlSize(.small)
                .disabled(isLoadingChunk || totalBytes == 0)
            }

            Divider()
                .frame(height: 16)

            HStack(spacing: 4) {
                Button {
                    loadChunk(atOffset: tab.streamingPrevOffset, totalBytes: totalBytes)
                } label: {
                    Label("Önceki", systemImage: "chevron.left")
                }
                .controlSize(.small)
                .disabled(isLoadingChunk || tab.streamingActualStart <= 0)

                Button {
                    loadChunk(atOffset: tab.streamingNextOffset, totalBytes: totalBytes)
                } label: {
                    Label("Sonraki", systemImage: "chevron.right")
                }
                .controlSize(.small)
                .disabled(isLoadingChunk || tab.streamingActualEnd >= totalBytes)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.06))
    }

    private func byteRangeSummary(totalBytes: Int64) -> String {
        let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let startStr = Self.numberFormatter.string(from: NSNumber(value: tab.streamingActualStart))
            ?? "\(tab.streamingActualStart)"
        let endStr = Self.numberFormatter.string(from: NSNumber(value: tab.streamingActualEnd))
            ?? "\(tab.streamingActualEnd)"
        return "\(startStr) – \(endStr) bayt / \(totalStr)"
    }

    private func loadChunk(atOffset offset: Int64, totalBytes: Int64) {
        isLoadingChunk = true
        Task {
            await store.loadStreamingChunk(for: tab, atOffset: offset)
            updateSliderFromCurrentOffset(totalBytes: totalBytes)
            isLoadingChunk = false
        }
    }

    private func updateSliderFromCurrentOffset(totalBytes: Int64) {
        guard totalBytes > 0 else {
            jumpPercent = 0
            return
        }
        let ratio = Double(tab.streamingActualStart) / Double(totalBytes)
        jumpPercent = max(0, min(100, ratio * 100.0))
    }

    private static let numberFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = true
        return nf
    }()
}

import SwiftUI

/// Compact Go-To-Line sheet (`⌘L` / `^G`) jumping directly to a 1-based line number.
public struct GoToLineSheetView: View {
    public let store: WindowTabStore
    @Environment(\.dismiss) private var dismiss

    @State private var lineInput: String = ""
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    public init(store: WindowTabStore) {
        self.store = store
    }

    public var body: some View {
        let tab = store.activeTab
        let totalLines = max(1, tab?.stats.lineCount ?? 1)
        let currentLine = tab?.cursorPosition.line ?? 1

        VStack(alignment: .leading, spacing: 14) {
            Text("Satıra Git")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Satır numarası (1 – \(totalLines)):")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Satır numarası", text: $lineInput)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .focused($isInputFocused)
                    .onSubmit {
                        submit(maxLine: totalLines)
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("İptal") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Git") {
                    submit(maxLine: totalLines)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            lineInput = "\(currentLine)"
            isInputFocused = true
        }
    }

    private func submit(maxLine: Int) {
        let trimmed = lineInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetLine = Int(trimmed), targetLine >= 1, targetLine <= maxLine else {
            errorMessage = "Lütfen 1 ile \(maxLine) arasında geçerli bir satır numarası girin."
            return
        }
        if store.goToLine(targetLine) {
            dismiss()
        } else {
            errorMessage = "Satır konumu hesaplanamadı."
        }
    }
}

import SwiftUI

/// Floating top-right Liquid Glass HUD for ReDoS-safe Find & Replace (`⌘F` / `⌥⌘F`).
public struct FindReplaceBarView: View {
    @Bindable public var store: WindowTabStore
    @FocusState private var focusedField: Field?

    private enum Field {
        case find
        case replace
    }

    public init(store: WindowTabStore) {
        self.store = store
    }

    public var body: some View {
        let isReadOnly = store.activeTab?.isReadOnlyLargeMode ?? false

        VStack(alignment: .leading, spacing: 8) {
            // Find row
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        store.isReplaceExpanded.toggle()
                    }
                } label: {
                    Image(systemName: store.isReplaceExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(isReadOnly)
                .help("Değiştir Panelini Aç/Kapat (⌥⌘F)")

                TextField("Bul...", text: $store.findQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(minWidth: 165, idealWidth: 205)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .focused($focusedField, equals: .find)
                    .onChange(of: store.findQuery) { _, _ in
                        store.scheduleSearch()
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            store.findPrevious()
                        } else {
                            store.findNext()
                        }
                        return .handled
                    }
                    .onExitCommand {
                        store.closeFindBar()
                    }

                if let badge = store.searchStatusBadge {
                    Text(badge)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(statusForegroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(statusBackgroundColor)
                        )
                        .help(store.searchRegexError ?? "")
                }

                // Search option toggles
                HStack(spacing: 2) {
                    optionToggleButton(
                        title: "Aa",
                        isOn: $store.searchOptions.caseSensitive,
                        tooltip: "Büyük/Küçük Harf Eşleştir"
                    )
                    optionToggleButton(
                        title: "ab",
                        isOn: $store.searchOptions.wholeWord,
                        tooltip: "Tam Sözcük Eşleştir"
                    )
                    optionToggleButton(
                        title: ".*",
                        isOn: $store.searchOptions.isRegex,
                        tooltip: "Düzenli İfade (Regex)"
                    )
                    optionToggleButton(
                        systemImage: "arrow.trianglehead.2.clockwise",
                        isOn: $store.searchOptions.wrapAround,
                        tooltip: "Başa Sar"
                    )
                }

                Divider()
                    .frame(height: 16)

                HStack(spacing: 2) {
                    Button {
                        store.findPrevious()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Öncekini Bul (⇧↩ / ⌘⇧G)")

                    Button {
                        store.findNext()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Sonrakini Bul (↩ / ⌘G)")

                    Button {
                        store.closeFindBar()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Kapat (Esc)")
                }
            }

            // Replace row
            if store.isReplaceExpanded && !isReadOnly {
                HStack(spacing: 6) {
                    Color.clear
                        .frame(width: 20, height: 1)

                    TextField("Değiştir...", text: $store.replaceQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .frame(minWidth: 165, idealWidth: 205)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                        .focused($focusedField, equals: .replace)
                        .onSubmit {
                            store.replaceCurrent()
                        }
                        .onExitCommand {
                            store.closeFindBar()
                        }

                    Button("Değiştir") {
                        store.replaceCurrent()
                    }
                    .controlSize(.small)
                    .disabled(store.findQuery.isEmpty)

                    Button("Tümünü Değiştir") {
                        Task {
                            await store.replaceAll()
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.findQuery.isEmpty)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 6)
        .onAppear {
            focusedField = .find
        }
        .onChange(of: store.searchOptions) { _, _ in
            store.scheduleSearch(immediate: true)
        }
    }

    private var statusForegroundColor: Color {
        if store.searchTimedOut || store.searchRegexError != nil {
            return .red
        }
        if store.searchMatches.isEmpty && !store.findQuery.isEmpty {
            return .secondary
        }
        return .primary
    }

    private var statusBackgroundColor: Color {
        if store.searchTimedOut || store.searchRegexError != nil {
            return Color.red.opacity(0.16)
        }
        return Color.primary.opacity(0.08)
    }

    private func optionToggleButton(
        title: String? = nil,
        systemImage: String? = nil,
        isOn: Binding<Bool>,
        tooltip: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                } else if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
            .frame(width: 24, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

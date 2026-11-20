import Foundation
import KadmosCore
import Observation

/// Represents an open editor document tab, supporting normal, >50 MB limited, and >1 GB streaming tiers.
@Observable
@MainActor
public final class DocumentTab: Identifiable {
    public let id: UUID
    public var fileURL: URL?
    public var untitledNumber: Int?
    public var customFilename: String?

    /// Plain-text buffer normalized to `\n` in memory.
    public var text: String

    /// Incremented ONLY on programmatic/external buffer replacements (load, reload, replace, F5 insert),
    /// never during normal `NSTextView` typing so cursor/IME state stays undisturbed.
    public var contentRevision: Int = 0

    public var encoding: KadmosTextEncoding
    public var lineEnding: KadmosLineEnding
    public var isDirty: Bool = false

    public var zoomPercent: Int {
        didSet {
            let clamped = Self.clampZoom(zoomPercent)
            if zoomPercent != clamped {
                zoomPercent = clamped
            }
        }
    }

    public var selectedRange: NSRange = NSRange(location: 0, length: 0)

    public var largeFileTier: LargeFileTier = .normal
    public var streamingReader: StreamingFileReader?
    public var streamingChunkText: String = ""
    public var streamingActualStart: Int64 = 0
    public var streamingActualEnd: Int64 = 0
    public var streamingPrevOffset: Int64 = 0
    public var streamingNextOffset: Int64 = 0

    public var hasEncodingWarning: Bool = false
    public var invalidEncodingCount: Int = 0

    public var trojanFindings: [TrojanFinding] = []
    public var isTrojanBannerDismissed: Bool = false
    public var isEncodingBannerDismissed: Bool = false
    public var isLargeFileBannerDismissed: Bool = false

    public let undoManager = UndoManager()
    public var bookmarkData: Data?

    // Fast-path cache to avoid recomputing word/line stats on pure cursor-movement redraws.
    @ObservationIgnored private var cachedMetricsText: String?
    @ObservationIgnored private var cachedMetricsSelection = NSRange(location: NSNotFound, length: 0)
    @ObservationIgnored private var cachedStatsValue = DocumentStats(
        lineCount: 1,
        characterCount: 0,
        wordCount: 0,
        selectedCharacterCount: 0
    )
    @ObservationIgnored private var cachedCursorLine: Int = 1
    @ObservationIgnored private var cachedCursorColumn: Int = 1

    public init(
        id: UUID = UUID(),
        fileURL: URL? = nil,
        untitledNumber: Int? = 1,
        customFilename: String? = nil,
        text: String = "",
        encoding: KadmosTextEncoding = .utf8,
        lineEnding: KadmosLineEnding = .lf,
        isDirty: Bool = false,
        zoomPercent: Int = 100,
        selectedRange: NSRange = NSRange(location: 0, length: 0),
        largeFileTier: LargeFileTier = .normal,
        streamingReader: StreamingFileReader? = nil,
        hasEncodingWarning: Bool = false,
        invalidEncodingCount: Int = 0,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.untitledNumber = untitledNumber
        self.customFilename = customFilename
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.isDirty = isDirty
        self.zoomPercent = Self.clampZoom(zoomPercent)
        self.selectedRange = selectedRange
        self.largeFileTier = largeFileTier
        self.streamingReader = streamingReader
        self.hasEncodingWarning = hasEncodingWarning
        self.invalidEncodingCount = invalidEncodingCount
        self.bookmarkData = bookmarkData
    }

    /// True when the document exceeds 1 GB and is opened in read-only streaming mode.
    public var isReadOnlyLargeMode: Bool {
        if case .streamingReadOnly = largeFileTier {
            return true
        }
        return false
    }

    /// True when the document is between 50 MB and 1 GB.
    public var isLimitedLargeMode: Bool {
        if case .limitedMode = largeFileTier {
            return true
        }
        return false
    }

    /// Tab label shown in the tab bar and confirmation alerts.
    public var displayTitle: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        if let customFilename, !customFilename.isEmpty {
            return customFilename
        }
        return "Adsız \(untitledNumber ?? 1)"
    }

    /// Editable filename pre-filled on inline rename (includes default `.txt` extension for untitled documents).
    public var defaultEditableFilename: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        if let customFilename, !customFilename.isEmpty {
            return customFilename
        }
        return "adsız\(untitledNumber ?? 1).txt"
    }

    /// Active text inspected by search, status metrics, and go-to-line (chunk text in streaming mode).
    public var activeBufferText: String {
        isReadOnlyLargeMode ? streamingChunkText : text
    }

    /// True when this is a pristine untitled tab that can be replaced on file open.
    public var isEmptyPristineUntitled: Bool {
        fileURL == nil && customFilename == nil && !isDirty && text.isEmpty && !isReadOnlyLargeMode
    }

    /// Document metrics computed via `LineColumnCalculator`.
    public var stats: DocumentStats {
        let buffer = activeBufferText
        let sel = selectedRange
        if let prevText = cachedMetricsText, prevText == buffer {
            if cachedMetricsSelection == sel {
                return cachedStatsValue
            }
            let selectedCount = Self.selectedCharacterCount(in: buffer, selectedRange: sel)
            let updated = DocumentStats(
                lineCount: cachedStatsValue.lineCount,
                characterCount: cachedStatsValue.characterCount,
                wordCount: cachedStatsValue.wordCount,
                selectedCharacterCount: selectedCount
            )
            cachedStatsValue = updated
            updateCachedCursorPosition(in: buffer, selection: sel)
            cachedMetricsSelection = sel
            return updated
        }

        let computed = LineColumnCalculator.stats(for: buffer, selectedRange: sel)
        cachedMetricsText = buffer
        cachedMetricsSelection = sel
        cachedStatsValue = computed
        updateCachedCursorPosition(in: buffer, selection: sel)
        return computed
    }

    /// 1-based `(line, column)` caret location computed via `LineColumnCalculator`.
    public var cursorPosition: (line: Int, column: Int) {
        let buffer = activeBufferText
        let sel = selectedRange
        if let prevText = cachedMetricsText, prevText == buffer, cachedMetricsSelection == sel {
            return (cachedCursorLine, cachedCursorColumn)
        }
        updateCachedCursorPosition(in: buffer, selection: sel)
        if cachedMetricsText != buffer {
            cachedMetricsText = buffer
            cachedStatsValue = LineColumnCalculator.stats(for: buffer, selectedRange: sel)
        }
        cachedMetricsSelection = sel
        return (cachedCursorLine, cachedCursorColumn)
    }

    /// Determines whether continuous spell checking should run for this document.
    public func shouldEnableSpellCheck(settings: KadmosSettings) -> Bool {
        guard settings.spellCheckEnabled, !isReadOnlyLargeMode, largeFileTier == .normal else {
            return false
        }
        let ext: String?
        if let fileURL {
            ext = fileURL.pathExtension.lowercased()
        } else if let customFilename {
            ext = (customFilename as NSString).pathExtension.lowercased()
        } else {
            ext = nil
        }
        if let ext, !ext.isEmpty {
            return !settings.spellCheckIgnoredExtensions.contains(ext)
        }
        return true
    }

    /// Rescans the active buffer for invisible/bidi Trojan Source control characters (`SECURITY.md` §3.6).
    public func refreshTrojanFindings(enabled: Bool) {
        guard enabled else {
            trojanFindings = []
            return
        }
        let buffer = activeBufferText
        if buffer.isEmpty {
            trojanFindings = []
            return
        }
        trojanFindings = TrojanSourceScanner.scan(buffer)
    }

    /// Bumps `contentRevision` to instruct `KadmosTextView` to pull programmatic changes.
    public func bumpContentRevision() {
        contentRevision &+= 1
    }

    private func updateCachedCursorPosition(in buffer: String, selection: NSRange) {
        let location = selection.location == NSNotFound ? 0 : selection.location
        let pos = LineColumnCalculator.position(in: buffer as NSString, utf16Location: location)
        cachedCursorLine = pos.line
        cachedCursorColumn = pos.column
    }

    private static func clampZoom(_ value: Int) -> Int {
        max(10, min(value, 500))
    }

    private static func selectedCharacterCount(in buffer: String, selectedRange: NSRange) -> Int {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            return 0
        }
        let nsText = buffer as NSString
        let safeLoc = max(0, min(selectedRange.location, nsText.length))
        let safeLen = max(0, min(selectedRange.length, nsText.length - safeLoc))
        guard safeLen > 0 else { return 0 }
        let clamped = NSRange(location: safeLoc, length: safeLen)
        if let swiftRange = Range(clamped, in: buffer) {
            return buffer[swiftRange].count
        }
        return nsText.substring(with: clamped).count
    }
}

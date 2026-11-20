import AppKit
import Foundation
import KadmosCore

/// Native AppKit plain-text editor view configured with TextKit 1 for deterministic
/// match highlighting, Trojan Source invisible-character overlays, pinch zoom, and plain-text fidelity.
@MainActor
public final class KadmosTextView: NSTextView {
    public var searchMatches: [NSRange] = [] {
        didSet {
            if searchMatches != oldValue {
                needsDisplay = true
            }
        }
    }

    public var currentMatchIndex: Int? = nil {
        didSet {
            if currentMatchIndex != oldValue {
                needsDisplay = true
            }
        }
    }

    public var trojanFindings: [TrojanFinding] = [] {
        didSet {
            if trojanFindings != oldValue {
                needsDisplay = true
            }
        }
    }

    public var highlightTrojanChars: Bool = true {
        didSet {
            if highlightTrojanChars != oldValue {
                needsDisplay = true
            }
        }
    }

    public var currentZoomPercent: Int = 100
    public var onZoomChange: ((Int) -> Void)?
    public var onInsertTimeDate: (() -> Void)?
    public var onFindNext: (() -> Void)?
    public var onFindPrevious: (() -> Void)?

    private var pinchZoomAccumulator: Double = 100.0
    private var scrollZoomRemainder: CGFloat = 0

    // MARK: - Strict Plain-Text Configuration

    public func configurePlainTextBehavior(
        spellCheckEnabled: Bool,
        autocorrectEnabled: Bool,
        isEditableDocument: Bool
    ) {
        isEditable = isEditableDocument
        isSelectable = true
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        allowsUndo = isEditableDocument
        usesFindBar = false
        allowsImageEditing = false

        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false

        isContinuousSpellCheckingEnabled = isEditableDocument && spellCheckEnabled
        isAutomaticSpellingCorrectionEnabled = isEditableDocument && spellCheckEnabled && autocorrectEnabled
        isGrammarCheckingEnabled = false

        writingToolsBehavior = isEditableDocument ? .complete : .none
        allowedWritingToolsResultOptions = [.plainText]

        textContainerInset = NSSize(width: 14, height: 14)
        drawsBackground = true
        backgroundColor = NSColor.textBackgroundColor
        insertionPointColor = NSColor.labelColor
    }

    public func applyWordWrap(_ enabled: Bool, in scrollView: NSScrollView) {
        guard let textContainer else { return }
        if enabled {
            scrollView.hasHorizontalScroller = false
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            let targetWidth = max(120, scrollView.contentSize.width)
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
            if abs(frame.size.width - targetWidth) > 0.5 {
                setFrameSize(NSSize(width: targetWidth, height: frame.size.height))
            }
        } else {
            scrollView.hasHorizontalScroller = true
            isHorizontallyResizable = true
            autoresizingMask = [.width, .height]
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager?.ensureLayout(for: textContainer)
        needsDisplay = true
    }

    // MARK: - Concealed Clipboard Protection (SECURITY.md §6)

    public override func paste(_ sender: Any?) {
        // Strictly paste plain text; never log or persist clipboard contents.
        pasteAsPlainText(sender)
    }

    // MARK: - Print & Page Setup

    public func runPrintDocument() {
        let printOp = NSPrintOperation(view: self)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        if let window {
            printOp.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            printOp.run()
        }
    }

    public func runPageSetup() {
        NSPageLayout().runModal()
    }

    // MARK: - Keyboard & Trackpad Shortcuts

    public override func keyDown(with event: NSEvent) {
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            let value = Int(scalar.value)
            if value == NSF5FunctionKey {
                if isEditable {
                    onInsertTimeDate?()
                }
                return
            }
            if value == NSF3FunctionKey {
                if event.modifierFlags.contains(.shift) {
                    onFindPrevious?()
                } else {
                    onFindNext?()
                }
                return
            }
        }

        // Physical keyCode fallback for F5 (96) and F3 (99)
        if event.keyCode == 96 {
            if isEditable {
                onInsertTimeDate?()
            }
            return
        }
        if event.keyCode == 99 {
            if event.modifierFlags.contains(.shift) {
                onFindPrevious?()
            } else {
                onFindNext?()
            }
            return
        }

        super.keyDown(with: event)
    }

    public override func magnify(with event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            pinchZoomAccumulator = Double(currentZoomPercent)
        }
        let nextValue = pinchZoomAccumulator * (1.0 + Double(event.magnification))
        pinchZoomAccumulator = max(10.0, min(500.0, nextValue))
        let rounded = Int(pinchZoomAccumulator.rounded())
        if rounded != currentZoomPercent {
            currentZoomPercent = rounded
            onZoomChange?(rounded)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), abs(event.scrollingDeltaY) > 0.05 {
            scrollZoomRemainder += event.scrollingDeltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 8.0 : 1.0
            if abs(scrollZoomRemainder) >= threshold {
                let steps = Int((scrollZoomRemainder / threshold).rounded(.towardZero))
                scrollZoomRemainder -= CGFloat(steps) * threshold
                let next = max(10, min(500, currentZoomPercent + steps * 5))
                if next != currentZoomPercent {
                    currentZoomPercent = next
                    onZoomChange?(next)
                }
            }
            return
        }
        super.scrollWheel(with: event)
    }

    // MARK: - Native Context Menu Additions

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }

        let sel = selectedRange()
        let hasSelection = sel.location != NSNotFound && sel.length > 0

        var insertIndex = 0
        if hasSelection {
            let searchItem = NSMenuItem(
                title: "Web'de Ara",
                action: #selector(searchSelectionInBrowser(_:)),
                keyEquivalent: ""
            )
            searchItem.target = self
            searchItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Web'de Ara")
            menu.insertItem(searchItem, at: insertIndex)
            insertIndex += 1
        }

        if isEditable {
            let dateItem = NSMenuItem(
                title: "Saat ve Tarih Ekle",
                action: #selector(insertTimeDateMenuAction(_:)),
                keyEquivalent: ""
            )
            dateItem.target = self
            dateItem.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Saat ve Tarih Ekle")
            menu.insertItem(dateItem, at: insertIndex)
            insertIndex += 1
        }

        if insertIndex > 0 {
            menu.insertItem(.separator(), at: insertIndex)
        }

        return menu
    }

    @objc private func insertTimeDateMenuAction(_ sender: Any?) {
        onInsertTimeDate?()
    }

    @objc private func searchSelectionInBrowser(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.location != NSNotFound, sel.length > 0 else { return }
        let nsText = string as NSString
        guard sel.location + sel.length <= nsText.length else { return }

        let rawQuery = nsText.substring(with: sel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.isEmpty else { return }

        let cappedQuery = String(rawQuery.prefix(500))
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: cappedQuery)]

        if let url = components.url {
            // Opens user's default browser externally; Kadmos performs zero network I/O (SECURITY.md §2.3).
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Custom Non-Destructive Overlays (Search Matches & Trojan Source Badges)

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager, let textContainer, let textStorage else {
            return
        }

        let totalLength = textStorage.length
        guard totalLength > 0 else { return }

        let containerOffset = textContainerOrigin
        let localRect = rect.offsetBy(dx: -containerOffset.x, dy: -containerOffset.y)
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: localRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        if visibleCharRange.length > 0 {
            drawSearchHighlights(
                visibleCharRange: visibleCharRange,
                totalLength: totalLength,
                layoutManager: layoutManager,
                textContainer: textContainer,
                origin: containerOffset
            )

            if highlightTrojanChars && !trojanFindings.isEmpty {
                drawTrojanSourceBadges(
                    visibleCharRange: visibleCharRange,
                    totalLength: totalLength,
                    layoutManager: layoutManager,
                    textContainer: textContainer,
                    origin: containerOffset
                )
            }
        }
    }

    private func drawSearchHighlights(
        visibleCharRange: NSRange,
        totalLength: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        origin: NSPoint
    ) {
        guard !searchMatches.isEmpty else { return }

        let visibleStart = visibleCharRange.location
        let visibleEnd = NSMaxRange(visibleCharRange)

        // Binary search to first match whose end exceeds visibleStart.
        var low = 0
        var high = searchMatches.count
        while low < high {
            let mid = low + (high - low) / 2
            if NSMaxRange(searchMatches[mid]) <= visibleStart {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let inactiveFill = NSColor.systemYellow.withAlphaComponent(0.28)
        let activeFill = NSColor.systemYellow.withAlphaComponent(0.62)
        let activeStroke = NSColor.systemOrange

        var idx = low
        while idx < searchMatches.count {
            let match = searchMatches[idx]
            if match.location >= visibleEnd {
                break
            }

            if match.location >= 0, match.length > 0, NSMaxRange(match) <= totalLength {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
                let isActive = (idx == currentMatchIndex)

                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { enclosingRect, _ in
                    let drawRect = enclosingRect
                        .offsetBy(dx: origin.x, dy: origin.y)
                        .insetBy(dx: -1.5, dy: 0)
                    let path = NSBezierPath(roundedRect: drawRect, xRadius: 3, yRadius: 3)
                    if isActive {
                        activeFill.setFill()
                        path.fill()
                        activeStroke.setStroke()
                        path.lineWidth = 1.25
                        path.stroke()
                    } else {
                        inactiveFill.setFill()
                        path.fill()
                    }
                }
            }

            idx += 1
        }
    }

    private func drawTrojanSourceBadges(
        visibleCharRange: NSRange,
        totalLength: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        origin: NSPoint
    ) {
        let visibleStart = visibleCharRange.location
        let visibleEnd = NSMaxRange(visibleCharRange)

        var low = 0
        var high = trojanFindings.count
        while low < high {
            let mid = low + (high - low) / 2
            if NSMaxRange(trojanFindings[mid].utf16Range) <= visibleStart {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let editorSize = font?.pointSize ?? 14.0
        let badgeFont = NSFont.monospacedSystemFont(ofSize: max(8.5, editorSize * 0.62), weight: .semibold)

        var idx = low
        while idx < trojanFindings.count {
            let finding = trojanFindings[idx]
            let charRange = finding.utf16Range
            if charRange.location >= visibleEnd {
                break
            }

            if charRange.location >= 0, charRange.length > 0, NSMaxRange(charRange) <= totalLength {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                var glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                    .offsetBy(dx: origin.x, dy: origin.y)

                let tag = finding.shortTag == "ZWNBSP" ? "BOM" : finding.shortTag
                let label = "[\(tag)]"
                let isBidi = (finding.category == .bidiControl)
                let fillColor = isBidi
                    ? NSColor.systemRed.withAlphaComponent(0.24)
                    : NSColor.systemOrange.withAlphaComponent(0.24)
                let strokeColor = isBidi ? NSColor.systemRed : NSColor.systemOrange
                let textColor = isBidi ? NSColor.systemRed : NSColor.systemOrange

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: badgeFont,
                    .foregroundColor: textColor
                ]
                let textSize = (label as NSString).size(withAttributes: attrs)
                let pillWidth = max(glyphRect.width, textSize.width + 6)
                let pillHeight = max(13, min(glyphRect.height, textSize.height + 2))
                glyphRect.origin.y += max(0, (glyphRect.height - pillHeight) / 2)
                glyphRect.size = NSSize(width: pillWidth, height: pillHeight)

                let pillPath = NSBezierPath(roundedRect: glyphRect, xRadius: 3.5, yRadius: 3.5)
                fillColor.setFill()
                pillPath.fill()
                strokeColor.withAlphaComponent(0.85).setStroke()
                pillPath.lineWidth = 0.9
                pillPath.stroke()

                let textOrigin = NSPoint(
                    x: glyphRect.origin.x + (pillWidth - textSize.width) / 2,
                    y: glyphRect.origin.y + (pillHeight - textSize.height) / 2
                )
                (label as NSString).draw(at: textOrigin, withAttributes: attrs)
            }

            idx += 1
        }
    }
}

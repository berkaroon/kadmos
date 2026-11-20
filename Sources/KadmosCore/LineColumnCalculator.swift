import Foundation

/// Summary metrics for an editor document.
public struct DocumentStats: Equatable, Sendable {
    public let lineCount: Int
    public let characterCount: Int
    public let wordCount: Int
    public let selectedCharacterCount: Int

    public init(
        lineCount: Int,
        characterCount: Int,
        wordCount: Int,
        selectedCharacterCount: Int
    ) {
        self.lineCount = lineCount
        self.characterCount = characterCount
        self.wordCount = wordCount
        self.selectedCharacterCount = selectedCharacterCount
    }
}

/// Fast UTF-16 line/column math and document statistics utilities.
public enum LineColumnCalculator: Sendable {
    private static let lfUnit: unichar = 0x000A
    private static let crUnit: unichar = 0x000D

    /// Computes 1-based `(line, column)` for `utf16Location` inside `text`.
    ///
    /// `column` is the 1-based UTF-16 code unit offset from the start of the line.
    /// Out-of-bounds locations are clamped safely to `0 ... text.length`.
    public static func position(in text: NSString, utf16Location: Int) -> (line: Int, column: Int) {
        let clampedLocation = max(0, min(utf16Location, text.length))
        var line = 1
        var lineStart = 0
        var index = 0

        while index < clampedLocation {
            let unit = text.character(at: index)
            if unit == lfUnit {
                line += 1
                index += 1
                lineStart = index
            } else if unit == crUnit {
                let nextIndex = index + 1
                if nextIndex < text.length && text.character(at: nextIndex) == lfUnit {
                    if nextIndex < clampedLocation {
                        line += 1
                        index += 2
                        lineStart = index
                    } else {
                        // Location falls between `\r` and `\n`; stay on current line.
                        index += 1
                    }
                } else {
                    line += 1
                    index += 1
                    lineStart = index
                }
            } else {
                index += 1
            }
        }

        let column = (clampedLocation - lineStart) + 1
        return (line, column)
    }

    /// Returns the starting UTF-16 offset for a 1-based line number, or `nil` if out of range.
    public static func utf16Offset(forLine oneBasedLine: Int, in text: NSString) -> Int? {
        guard oneBasedLine >= 1 else {
            return nil
        }
        if oneBasedLine == 1 {
            return 0
        }

        let length = text.length
        var currentLine = 1
        var index = 0

        while index < length {
            let unit = text.character(at: index)
            if unit == lfUnit {
                currentLine += 1
                index += 1
                if currentLine == oneBasedLine {
                    return index
                }
            } else if unit == crUnit {
                currentLine += 1
                let nextIndex = index + 1
                if nextIndex < length && text.character(at: nextIndex) == lfUnit {
                    index += 2
                } else {
                    index += 1
                }
                if currentLine == oneBasedLine {
                    return index
                }
            } else {
                index += 1
            }
        }

        return nil
    }

    /// Computes line count, character count, word count, and selected character count.
    public static func stats(for text: String, selectedRange: NSRange) -> DocumentStats {
        let lineCount = countLines(in: text)
        let characterCount = text.count
        let wordCount = countWords(in: text)
        let selectedCharacterCount = countSelectedCharacters(in: text, selectedRange: selectedRange)

        return DocumentStats(
            lineCount: lineCount,
            characterCount: characterCount,
            wordCount: wordCount,
            selectedCharacterCount: selectedCharacterCount
        )
    }

    private static func countLines(in text: String) -> Int {
        let utf8 = text.utf8
        var lines = 1
        var index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            let nextIndex = utf8.index(after: index)
            if byte == 0x0A {
                lines += 1
            } else if byte == 0x0D {
                lines += 1
                if nextIndex < utf8.endIndex && utf8[nextIndex] == 0x0A {
                    index = utf8.index(after: nextIndex)
                    continue
                }
            }
            index = nextIndex
        }
        return lines
    }

    private static func countWords(in text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private static func countSelectedCharacters(in text: String, selectedRange: NSRange) -> Int {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            return 0
        }
        let nsText = text as NSString
        let safeLocation = max(0, min(selectedRange.location, nsText.length))
        let safeLength = max(0, min(selectedRange.length, nsText.length - safeLocation))
        guard safeLength > 0 else {
            return 0
        }

        let clamped = NSRange(location: safeLocation, length: safeLength)
        if let swiftRange = Range(clamped, in: text) {
            return text[swiftRange].count
        }
        return nsText.substring(with: clamped).count
    }
}

import Foundation

/// A single Trojan Source / invisible Unicode control character finding (`SECURITY.md` §3.6).
public struct TrojanFinding: Equatable, Identifiable, Sendable {
    public enum Category: String, Equatable, Sendable {
        case bidiControl
        case zeroWidth
        case hiddenMarker
    }

    public let id: Int
    public let utf16Range: NSRange
    public let scalarValue: UInt32
    public let shortTag: String
    public let category: Category
    public let description: String

    public init(
        id: Int,
        utf16Range: NSRange,
        scalarValue: UInt32,
        shortTag: String,
        category: Category,
        description: String
    ) {
        self.id = id
        self.utf16Range = utf16Range
        self.scalarValue = scalarValue
        self.shortTag = shortTag
        self.category = category
        self.description = description
    }
}

/// Scans text for bidirectional overrides/isolates and invisible zero-width characters.
public enum TrojanSourceScanner: Sendable {
    public static let defaultMaxFindings = 10_000
    public static let defaultMaxCharacters = 2_000_000

    /// Scans `text` for Trojan Source bidi controls and invisible characters, returning bounded findings
    /// with exact UTF-16 `NSRange` locations.
    public static func scan(
        _ text: String,
        maxFindings: Int = defaultMaxFindings,
        maxCharacters: Int = defaultMaxCharacters
    ) -> [TrojanFinding] {
        guard maxFindings > 0, maxCharacters > 0, !text.isEmpty else {
            return []
        }

        var findings: [TrojanFinding] = []
        var utf16Offset = 0
        var scalarCount = 0

        for scalar in text.unicodeScalars {
            if scalarCount >= maxCharacters || findings.count >= maxFindings {
                break
            }

            let utf16Length = scalar.utf16.count
            if let metadata = classify(scalar) {
                let finding = TrojanFinding(
                    id: findings.count,
                    utf16Range: NSRange(location: utf16Offset, length: utf16Length),
                    scalarValue: scalar.value,
                    shortTag: metadata.shortTag,
                    category: metadata.category,
                    description: metadata.description
                )
                findings.append(finding)
            }

            utf16Offset += utf16Length
            scalarCount += 1
        }

        return findings
    }

    /// Classifies an individual `UnicodeScalar` if it is a tracked bidi control or invisible marker.
    public static func classify(
        _ scalar: UnicodeScalar
    ) -> (category: TrojanFinding.Category, shortTag: String, description: String)? {
        switch scalar.value {
        // Bidirectional embeddings / overrides / pop
        case 0x202A: return (.bidiControl, "LRE", "Left-to-Right Embedding (U+202A)")
        case 0x202B: return (.bidiControl, "RLE", "Right-to-Left Embedding (U+202B)")
        case 0x202C: return (.bidiControl, "PDF", "Pop Directional Formatting (U+202C)")
        case 0x202D: return (.bidiControl, "LRO", "Left-to-Right Override (U+202D)")
        case 0x202E: return (.bidiControl, "RLO", "Right-to-Left Override (U+202E)")

        // Bidirectional isolates
        case 0x2066: return (.bidiControl, "LRI", "Left-to-Right Isolate (U+2066)")
        case 0x2067: return (.bidiControl, "RLI", "Right-to-Left Isolate (U+2067)")
        case 0x2068: return (.bidiControl, "FSI", "First Strong Isolate (U+2068)")
        case 0x2069: return (.bidiControl, "PDI", "Pop Directional Isolate (U+2069)")

        // Bidirectional marks
        case 0x200E: return (.bidiControl, "LRM", "Left-to-Right Mark (U+200E)")
        case 0x200F: return (.bidiControl, "RLM", "Right-to-Left Mark (U+200F)")
        case 0x061C: return (.bidiControl, "ALM", "Arabic Letter Mark (U+061C)")

        // Zero-width characters
        case 0x200B: return (.zeroWidth, "ZWSP", "Zero Width Space (U+200B)")
        case 0x200C: return (.zeroWidth, "ZWNJ", "Zero Width Non-Joiner (U+200C)")
        case 0x200D: return (.zeroWidth, "ZWJ", "Zero Width Joiner (U+200D)")
        case 0x2060: return (.zeroWidth, "WJ", "Word Joiner (U+2060)")

        // Hidden markers
        case 0xFEFF: return (.hiddenMarker, "ZWNBSP", "Byte Order Mark / Zero Width No-Break Space (U+FEFF)")

        default:
            return nil
        }
    }
}

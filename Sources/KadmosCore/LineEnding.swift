import Foundation

/// Supported line ending conventions in Kadmos.
public enum KadmosLineEnding: String, CaseIterable, Codable, Sendable, Identifiable {
    case lf
    case crlf
    case cr

    public var id: String { rawValue }

    /// Descriptive name shown in UI menus.
    public var displayName: String {
        switch self {
        case .lf: return "Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr: return "Macintosh (CR)"
        }
    }

    /// Short status bar label.
    public var shortStatusName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    /// Exact character sequence representing this line ending.
    public var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// Pure, O(N) line ending detection, normalization, and serialization utilities.
public enum LineEndingCodec: Sendable {
    private static let lfByte: UInt8 = 0x0A
    private static let crByte: UInt8 = 0x0D

    /// Detects the dominant line ending in `text`.
    ///
    /// On ties between non-zero counts, prefers `.crlf` > `.lf` > `.cr`.
    /// Returns `.lf` when the text is empty or contains no line breaks.
    public static func detect(in text: String) -> KadmosLineEnding {
        var crlfCount = 0
        var lfCount = 0
        var crCount = 0

        let utf8 = text.utf8
        var index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            let nextIndex = utf8.index(after: index)
            if byte == crByte {
                if nextIndex < utf8.endIndex && utf8[nextIndex] == lfByte {
                    crlfCount += 1
                    index = utf8.index(after: nextIndex)
                    continue
                }
                crCount += 1
            } else if byte == lfByte {
                lfCount += 1
            }
            index = nextIndex
        }

        let maxCount = max(crlfCount, max(lfCount, crCount))
        if maxCount == 0 {
            return .lf
        }
        if crlfCount == maxCount {
            return .crlf
        }
        if lfCount == maxCount {
            return .lf
        }
        return .cr
    }

    /// Normalizes all `\r\n` and `\r` line breaks to `\n`.
    public static func normalizeToLF(_ text: String) -> String {
        let utf8 = text.utf8
        if !utf8.contains(crByte) {
            return text
        }

        var output: [UInt8] = []
        output.reserveCapacity(utf8.count)

        var index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            let nextIndex = utf8.index(after: index)
            if byte == crByte {
                output.append(lfByte)
                if nextIndex < utf8.endIndex && utf8[nextIndex] == lfByte {
                    index = utf8.index(after: nextIndex)
                    continue
                }
            } else {
                output.append(byte)
            }
            index = nextIndex
        }

        return String(decoding: output, as: UTF8.self)
    }

    /// Normalizes any existing `\r\n` or `\r` to `\n`, then converts all `\n` to `lineEnding`.
    public static func serialize(_ text: String, as lineEnding: KadmosLineEnding) -> String {
        switch lineEnding {
        case .lf:
            return normalizeToLF(text)
        case .crlf, .cr:
            let utf8 = text.utf8
            let targetBytes: [UInt8] = (lineEnding == .crlf) ? [crByte, lfByte] : [crByte]
            var output: [UInt8] = []
            output.reserveCapacity(utf8.count + (lineEnding == .crlf ? utf8.count / 16 : 0))

            var index = utf8.startIndex
            while index < utf8.endIndex {
                let byte = utf8[index]
                let nextIndex = utf8.index(after: index)
                if byte == crByte {
                    output.append(contentsOf: targetBytes)
                    if nextIndex < utf8.endIndex && utf8[nextIndex] == lfByte {
                        index = utf8.index(after: nextIndex)
                        continue
                    }
                } else if byte == lfByte {
                    output.append(contentsOf: targetBytes)
                } else {
                    output.append(byte)
                }
                index = nextIndex
            }

            return String(decoding: output, as: UTF8.self)
        }
    }
}

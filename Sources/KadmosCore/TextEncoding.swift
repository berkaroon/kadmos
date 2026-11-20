import Foundation

/// Supported character encodings in Kadmos.
public enum KadmosTextEncoding: String, CaseIterable, Codable, Sendable, Identifiable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case windows1254
    case windows1252
    case isoLatin1
    case macOSRoman

    public var id: String { rawValue }

    /// Human-readable encoding name shown in menus and dialogs.
    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 (BOM)"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .windows1254: return "ANSI (Windows-1254)"
        case .windows1252: return "ANSI (Windows-1252)"
        case .isoLatin1: return "ISO Latin 1"
        case .macOSRoman: return "Mac OS Roman"
        }
    }

    /// Compact encoding label shown in the status bar.
    public var shortStatusName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .windows1254: return "Windows-1254"
        case .windows1252: return "Windows-1252"
        case .isoLatin1: return "ISO Latin 1"
        case .macOSRoman: return "Mac OS Roman"
        }
    }

    /// Underlying Foundation `String.Encoding`.
    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM:
            return .utf8
        case .utf16LE:
            return .utf16LittleEndian
        case .utf16BE:
            return .utf16BigEndian
        case .windows1254:
            let cfEncoding = CFStringEncoding(CFStringEncodings.windowsLatin5.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        case .windows1252:
            return .windowsCP1252
        case .isoLatin1:
            return .isoLatin1
        case .macOSRoman:
            return .macOSRoman
        }
    }

    /// Raw `NSStringEncoding` value corresponding to `stringEncoding`.
    public var nsStringEncoding: UInt {
        stringEncoding.rawValue
    }
}

/// Result of decoding raw file bytes into a Swift `String`.
public struct DecodedTextResult: Equatable, Sendable {
    public let text: String
    public let encoding: KadmosTextEncoding
    public let hadInvalidSequences: Bool
    public let invalidSequenceCount: Int

    public init(
        text: String,
        encoding: KadmosTextEncoding,
        hadInvalidSequences: Bool,
        invalidSequenceCount: Int
    ) {
        self.text = text
        self.encoding = encoding
        self.hadInvalidSequences = hadInvalidSequences
        self.invalidSequenceCount = invalidSequenceCount
    }
}

/// Errors produced when encoding text into a specific byte format.
public enum TextEncodingError: Error, LocalizedError, Equatable, Sendable {
    case unrepresentableCharacters(encoding: KadmosTextEncoding)

    public var errorDescription: String? {
        switch self {
        case .unrepresentableCharacters(let encoding):
            return "Text contains characters that cannot be represented in \(encoding.displayName) without data loss."
        }
    }
}

/// Safe, crash-free text codec supporting BOM detection, lossy U+FFFD substitution, and strict encoding.
///
/// Invalid byte sequences never trigger crashes or silent encoding guesswork (`SECURITY.md` §3.5).
public enum TextEncodingCodec: Sendable {
    private static let utf8BOMBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LEBOMBytes: [UInt8] = [0xFF, 0xFE]
    private static let utf16BEBOMBytes: [UInt8] = [0xFE, 0xFF]

    /// Detects BOMs (`UTF-8 BOM`, `UTF-16 LE`, `UTF-16 BE`) or defaults to UTF-8.
    ///
    /// Invalid UTF-8 or UTF-16 sequences are replaced with `U+FFFD` rather than
    /// silently guessing an 8-bit ANSI code page.
    public static func detectAndDecode(_ data: Data) -> DecodedTextResult {
        if data.isEmpty {
            return DecodedTextResult(
                text: "",
                encoding: .utf8,
                hadInvalidSequences: false,
                invalidSequenceCount: 0
            )
        }

        if data.starts(with: utf8BOMBytes) {
            return decodeUTF8(data.dropFirst(3), encoding: .utf8BOM)
        }
        if data.starts(with: utf16LEBOMBytes) {
            return decodeUTF16(data.dropFirst(2), littleEndian: true, encoding: .utf16LE)
        }
        if data.starts(with: utf16BEBOMBytes) {
            return decodeUTF16(data.dropFirst(2), littleEndian: false, encoding: .utf16BE)
        }

        return decodeUTF8(data[...], encoding: .utf8)
    }

    /// Explicitly decodes `data` using the requested encoding (for "Reopen with Encoding").
    public static func decode(_ data: Data, as encoding: KadmosTextEncoding) -> DecodedTextResult {
        switch encoding {
        case .utf8:
            return decodeUTF8(data[...], encoding: .utf8)
        case .utf8BOM:
            let payload = data.starts(with: utf8BOMBytes) ? data.dropFirst(3) : data[...]
            return decodeUTF8(payload, encoding: .utf8BOM)
        case .utf16LE:
            let payload = data.starts(with: utf16LEBOMBytes) ? data.dropFirst(2) : data[...]
            return decodeUTF16(payload, littleEndian: true, encoding: .utf16LE)
        case .utf16BE:
            let payload = data.starts(with: utf16BEBOMBytes) ? data.dropFirst(2) : data[...]
            return decodeUTF16(payload, littleEndian: false, encoding: .utf16BE)
        case .windows1254, .windows1252, .isoLatin1, .macOSRoman:
            return decodeSingleByte(data, as: encoding)
        }
    }

    /// Returns `true` if `text` can be encoded using `encoding` with zero character loss.
    public static func canLosslesslyEncode(_ text: String, as encoding: KadmosTextEncoding) -> Bool {
        switch encoding {
        case .utf8, .utf8BOM, .utf16LE, .utf16BE:
            return true
        case .windows1254, .windows1252, .isoLatin1, .macOSRoman:
            return text.data(using: encoding.stringEncoding, allowLossyConversion: false) != nil
        }
    }

    /// Encodes `text` into bytes for `encoding`, inserting exact BOM bytes when applicable.
    ///
    /// Throws `TextEncodingError.unrepresentableCharacters` for 8-bit encodings when
    /// `allowLossy` is `false` and characters cannot be represented losslessly.
    public static func encode(
        _ text: String,
        as encoding: KadmosTextEncoding,
        allowLossy: Bool = false
    ) throws -> Data {
        switch encoding {
        case .utf8:
            return Data(text.utf8)

        case .utf8BOM:
            var out = Data(capacity: 3 + text.utf8.count)
            out.append(contentsOf: utf8BOMBytes)
            out.append(contentsOf: text.utf8)
            return out

        case .utf16LE:
            return encodeUTF16(text, littleEndian: true)

        case .utf16BE:
            return encodeUTF16(text, littleEndian: false)

        case .windows1254, .windows1252, .isoLatin1, .macOSRoman:
            if let strictData = text.data(using: encoding.stringEncoding, allowLossyConversion: false) {
                return strictData
            }
            if allowLossy, let lossyData = text.data(using: encoding.stringEncoding, allowLossyConversion: true) {
                return lossyData
            }
            throw TextEncodingError.unrepresentableCharacters(encoding: encoding)
        }
    }

    // MARK: - Private Helpers

    private static func decodeUTF8(_ bytes: Data.SubSequence, encoding: KadmosTextEncoding) -> DecodedTextResult {
        if bytes.isEmpty {
            return DecodedTextResult(
                text: "",
                encoding: encoding,
                hadInvalidSequences: false,
                invalidSequenceCount: 0
            )
        }

        if let strict = String(data: Data(bytes), encoding: .utf8) {
            return DecodedTextResult(
                text: strict,
                encoding: encoding,
                hadInvalidSequences: false,
                invalidSequenceCount: 0
            )
        }

        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        var invalidCount = 0

        decodingLoop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
            case .emptyInput:
                break decodingLoop
            case .error:
                invalidCount += 1
                scalars.append("\u{FFFD}")
            }
        }

        return DecodedTextResult(
            text: String(scalars),
            encoding: encoding,
            hadInvalidSequences: invalidCount > 0,
            invalidSequenceCount: invalidCount
        )
    }

    private static func decodeUTF16(
        _ bytes: Data.SubSequence,
        littleEndian: Bool,
        encoding: KadmosTextEncoding
    ) -> DecodedTextResult {
        if bytes.isEmpty {
            return DecodedTextResult(
                text: "",
                encoding: encoding,
                hadInvalidSequences: false,
                invalidSequenceCount: 0
            )
        }

        let pairCount = bytes.count / 2
        let hasTrailingOddByte = (bytes.count % 2) != 0

        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(pairCount)
        var idx = bytes.startIndex
        for _ in 0..<pairCount {
            let b0 = bytes[idx]
            idx = bytes.index(after: idx)
            let b1 = bytes[idx]
            idx = bytes.index(after: idx)
            let unit: UInt16 = littleEndian
                ? (UInt16(b0) | (UInt16(b1) << 8))
                : ((UInt16(b0) << 8) | UInt16(b1))
            codeUnits.append(unit)
        }

        var decoder = UTF16()
        var iterator = codeUnits.makeIterator()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(pairCount)
        var invalidCount = 0

        decodingLoop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
            case .emptyInput:
                break decodingLoop
            case .error:
                invalidCount += 1
                scalars.append("\u{FFFD}")
            }
        }

        if hasTrailingOddByte {
            invalidCount += 1
            scalars.append("\u{FFFD}")
        }

        return DecodedTextResult(
            text: String(scalars),
            encoding: encoding,
            hadInvalidSequences: invalidCount > 0,
            invalidSequenceCount: invalidCount
        )
    }

    private static func decodeSingleByte(_ data: Data, as encoding: KadmosTextEncoding) -> DecodedTextResult {
        if data.isEmpty {
            return DecodedTextResult(
                text: "",
                encoding: encoding,
                hadInvalidSequences: false,
                invalidSequenceCount: 0
            )
        }

        if let decoded = String(data: data, encoding: encoding.stringEncoding) {
            return DecodedTextResult(
                text: decoded,
                encoding: encoding,
                hadInvalidSequences: false,
                invalidSequenceCount: 0
            )
        }

        var result = String()
        result.reserveCapacity(data.count)
        var invalidCount = 0

        for byte in data {
            if let charStr = String(bytes: [byte], encoding: encoding.stringEncoding) {
                result.append(charStr)
            } else {
                invalidCount += 1
                result.append("\u{FFFD}")
            }
        }

        return DecodedTextResult(
            text: result,
            encoding: encoding,
            hadInvalidSequences: invalidCount > 0,
            invalidSequenceCount: invalidCount
        )
    }

    private static func encodeUTF16(_ text: String, littleEndian: Bool) -> Data {
        let bom = littleEndian ? utf16LEBOMBytes : utf16BEBOMBytes
        let utf16Units = text.utf16
        var out = Data(capacity: 2 + utf16Units.count * 2)
        out.append(contentsOf: bom)

        for unit in utf16Units {
            let low = UInt8(unit & 0xFF)
            let high = UInt8(unit >> 8)
            if littleEndian {
                out.append(low)
                out.append(high)
            } else {
                out.append(high)
                out.append(low)
            }
        }
        return out
    }
}

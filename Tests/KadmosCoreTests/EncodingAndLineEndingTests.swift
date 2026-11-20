import Foundation
import XCTest
@testable import KadmosCore

final class EncodingAndLineEndingTests: XCTestCase {
    func testDetectAndDecodeEmptyData() {
        let result = TextEncodingCodec.detectAndDecode(Data())
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertFalse(result.hadInvalidSequences)
        XCTAssertEqual(result.invalidSequenceCount, 0)
    }

    func testDetectAndDecodeUTF8WithoutBOM() {
        let original = "Merhaba dünya — ğüşöçıİĞÜŞÖÇ 🚀"
        let result = TextEncodingCodec.detectAndDecode(Data(original.utf8))
        XCTAssertEqual(result.text, original)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertFalse(result.hadInvalidSequences)
        XCTAssertEqual(result.invalidSequenceCount, 0)
    }

    func testDetectAndDecodeBOMVariants() throws {
        let sample = "Kadmos ÇŞĞÜÖİ 🚀"

        let utf8BOM = try TextEncodingCodec.encode(sample, as: .utf8BOM)
        XCTAssertTrue(utf8BOM.starts(with: [0xEF, 0xBB, 0xBF]))
        let decodedUTF8BOM = TextEncodingCodec.detectAndDecode(utf8BOM)
        XCTAssertEqual(decodedUTF8BOM.encoding, .utf8BOM)
        XCTAssertEqual(decodedUTF8BOM.text, sample)
        XCTAssertFalse(decodedUTF8BOM.hadInvalidSequences)

        let utf16LE = try TextEncodingCodec.encode(sample, as: .utf16LE)
        XCTAssertTrue(utf16LE.starts(with: [0xFF, 0xFE]))
        let decodedLE = TextEncodingCodec.detectAndDecode(utf16LE)
        XCTAssertEqual(decodedLE.encoding, .utf16LE)
        XCTAssertEqual(decodedLE.text, sample)
        XCTAssertFalse(decodedLE.hadInvalidSequences)

        let utf16BE = try TextEncodingCodec.encode(sample, as: .utf16BE)
        XCTAssertTrue(utf16BE.starts(with: [0xFE, 0xFF]))
        let decodedBE = TextEncodingCodec.detectAndDecode(utf16BE)
        XCTAssertEqual(decodedBE.encoding, .utf16BE)
        XCTAssertEqual(decodedBE.text, sample)
        XCTAssertFalse(decodedBE.hadInvalidSequences)
    }

    func testInvalidUTF8ReplacesWithFFFDWithoutSilentANSIFallback() {
        // 'A' + invalid 2-byte lead 0xC3 followed by '(' + invalid byte 0xFF + 'B'
        let raw = Data([0x41, 0xC3, 0x28, 0xFF, 0x42])
        let result = TextEncodingCodec.detectAndDecode(raw)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertTrue(result.hadInvalidSequences)
        XCTAssertEqual(result.invalidSequenceCount, 2)
        XCTAssertEqual(result.text, "A\u{FFFD}(\u{FFFD}B")
    }

    func testInvalidUTF8CountsOnlyNewlyIntroducedErrorsEvenWhenFFFDExists() {
        // Valid U+FFFD (EF BF BD) followed by invalid byte 0xFF
        let raw = Data([0xEF, 0xBF, 0xBD, 0xFF])
        let result = TextEncodingCodec.detectAndDecode(raw)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertTrue(result.hadInvalidSequences)
        XCTAssertEqual(result.invalidSequenceCount, 1)
        XCTAssertEqual(result.text, "\u{FFFD}\u{FFFD}")
    }

    func testInvalidUTF16OddByteAndLoneSurrogateDoNotCrash() {
        // UTF-16 LE BOM + 'A' (0x41, 0x00) + trailing odd byte 0x42
        let oddLE = Data([0xFF, 0xFE, 0x41, 0x00, 0x42])
        let decodedOdd = TextEncodingCodec.detectAndDecode(oddLE)
        XCTAssertEqual(decodedOdd.encoding, .utf16LE)
        XCTAssertTrue(decodedOdd.hadInvalidSequences)
        XCTAssertEqual(decodedOdd.invalidSequenceCount, 1)
        XCTAssertEqual(decodedOdd.text, "A\u{FFFD}")

        // UTF-16 BE BOM + lone high surrogate 0xD800 + 'A' (0x00, 0x41)
        let loneSurrogateBE = Data([0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x41])
        let decodedSurrogate = TextEncodingCodec.detectAndDecode(loneSurrogateBE)
        XCTAssertEqual(decodedSurrogate.encoding, .utf16BE)
        XCTAssertTrue(decodedSurrogate.hadInvalidSequences)
        XCTAssertEqual(decodedSurrogate.invalidSequenceCount, 1)
        XCTAssertEqual(decodedSurrogate.text, "\u{FFFD}A")
    }

    func testWindows1254AndOtherEightBitEncodingsRoundtrip() throws {
        let turkish = "ğüşöçıİĞÜŞÖÇ"
        let win1254Data = try TextEncodingCodec.encode(turkish, as: .windows1254)
        // Verify exact Windows-1254 byte for 'ğ' (0xF0) and 'ş' (0xFE)
        XCTAssertEqual(win1254Data.first, 0xF0)
        XCTAssertEqual(win1254Data[2], 0xFE)

        let decoded1254 = TextEncodingCodec.decode(win1254Data, as: .windows1254)
        XCTAssertEqual(decoded1254.text, turkish)
        XCTAssertEqual(decoded1254.encoding, .windows1254)
        XCTAssertFalse(decoded1254.hadInvalidSequences)

        let win1252Sample = "Café €100"
        let win1252Data = try TextEncodingCodec.encode(win1252Sample, as: .windows1252)
        XCTAssertEqual(TextEncodingCodec.decode(win1252Data, as: .windows1252).text, win1252Sample)

        let latin1Sample = "Café naïve"
        let latin1Data = try TextEncodingCodec.encode(latin1Sample, as: .isoLatin1)
        XCTAssertEqual(TextEncodingCodec.decode(latin1Data, as: .isoLatin1).text, latin1Sample)

        let macRomanSample = "Apple • Café — π"
        let macRomanData = try TextEncodingCodec.encode(macRomanSample, as: .macOSRoman)
        XCTAssertEqual(TextEncodingCodec.decode(macRomanData, as: .macOSRoman).text, macRomanSample)
    }

    func testWindows1254UndefinedByteProducesReplacement() {
        // 0x81 is undefined in Windows-1254
        let raw = Data([0x41, 0x81, 0xF0])
        let decoded = TextEncodingCodec.decode(raw, as: .windows1254)
        XCTAssertTrue(decoded.hadInvalidSequences)
        XCTAssertEqual(decoded.invalidSequenceCount, 1)
        XCTAssertEqual(decoded.text, "A\u{FFFD}ğ")
    }

    func testUnrepresentableCharacterThrowsUnlessLossyRequested() throws {
        XCTAssertFalse(TextEncodingCodec.canLosslesslyEncode("Hello 🚀", as: .windows1252))
        XCTAssertThrowsError(try TextEncodingCodec.encode("Hello 🚀", as: .windows1252)) { error in
            XCTAssertEqual(error as? TextEncodingError, .unrepresentableCharacters(encoding: .windows1252))
        }
        let lossyData = try TextEncodingCodec.encode("Hello 🚀", as: .windows1252, allowLossy: true)
        XCTAssertFalse(lossyData.isEmpty)
    }

    func testLineEndingDetectionMajorityAndTieBreaking() {
        XCTAssertEqual(LineEndingCodec.detect(in: ""), .lf)
        XCTAssertEqual(LineEndingCodec.detect(in: "single line"), .lf)
        XCTAssertEqual(LineEndingCodec.detect(in: "a\nb\nc\r\nd"), .lf)
        XCTAssertEqual(LineEndingCodec.detect(in: "a\r\nb\r\nc\nd"), .crlf)
        XCTAssertEqual(LineEndingCodec.detect(in: "a\rb\rc\nd"), .cr)

        // Tie breaking: .crlf > .lf > .cr
        XCTAssertEqual(LineEndingCodec.detect(in: "a\r\nb\nc"), .crlf)
        XCTAssertEqual(LineEndingCodec.detect(in: "a\nb\rc"), .lf)
        XCTAssertEqual(LineEndingCodec.detect(in: "a\r\nb\rc"), .crlf)
        XCTAssertEqual(LineEndingCodec.detect(in: "a\r\nb\nc\rd"), .crlf)
    }

    func testLineEndingNormalizationAndSerialization() {
        let mixed = "one\r\ntwo\rthree\nfour\r\n\r\n"
        XCTAssertEqual(LineEndingCodec.normalizeToLF(mixed), "one\ntwo\nthree\nfour\n\n")
        XCTAssertEqual(LineEndingCodec.serialize(mixed, as: .lf), "one\ntwo\nthree\nfour\n\n")
        XCTAssertEqual(LineEndingCodec.serialize(mixed, as: .crlf), "one\r\ntwo\r\nthree\r\nfour\r\n\r\n")
        XCTAssertEqual(LineEndingCodec.serialize(mixed, as: .cr), "one\rtwo\rthree\rfour\r\r")
    }
}

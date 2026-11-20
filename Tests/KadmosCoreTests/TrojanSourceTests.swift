import Foundation
import XCTest
@testable import KadmosCore

final class TrojanSourceTests: XCTestCase {
    func testCleanTextProducesZeroFindings() {
        let clean = "func greet(name: String) -> String { return \"Merhaba \(name) 🚀\" }"
        XCTAssertTrue(TrojanSourceScanner.scan(clean).isEmpty)
    }

    func testDetectsAllBidiControlsZeroWidthAndHiddenMarkers() {
        let scalars: [(UnicodeScalar, TrojanFinding.Category, String)] = [
            ("\u{202A}", .bidiControl, "LRE"),
            ("\u{202B}", .bidiControl, "RLE"),
            ("\u{202C}", .bidiControl, "PDF"),
            ("\u{202D}", .bidiControl, "LRO"),
            ("\u{202E}", .bidiControl, "RLO"),
            ("\u{2066}", .bidiControl, "LRI"),
            ("\u{2067}", .bidiControl, "RLI"),
            ("\u{2068}", .bidiControl, "FSI"),
            ("\u{2069}", .bidiControl, "PDI"),
            ("\u{200E}", .bidiControl, "LRM"),
            ("\u{200F}", .bidiControl, "RLM"),
            ("\u{061C}", .bidiControl, "ALM"),
            ("\u{200B}", .zeroWidth, "ZWSP"),
            ("\u{200C}", .zeroWidth, "ZWNJ"),
            ("\u{200D}", .zeroWidth, "ZWJ"),
            ("\u{2060}", .zeroWidth, "WJ"),
            ("\u{FEFF}", .hiddenMarker, "ZWNBSP")
        ]

        let combined = String(String.UnicodeScalarView(scalars.map(\.0)))
        let findings = TrojanSourceScanner.scan(combined)

        XCTAssertEqual(findings.count, scalars.count)
        for (index, item) in scalars.enumerated() {
            XCTAssertEqual(findings[index].scalarValue, item.0.value)
            XCTAssertEqual(findings[index].category, item.1)
            XCTAssertEqual(findings[index].shortTag, item.2)
            XCTAssertEqual(findings[index].utf16Range, NSRange(location: index, length: 1))
        }
    }

    func testUTF16OffsetsStayExactAfterSurrogatePairEmoji() {
        // '🚀' occupies 2 UTF-16 code units, so U+202E sits at UTF-16 location 2.
        let payload = "🚀\u{202E}admin"
        let findings = TrojanSourceScanner.scan(payload)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].shortTag, "RLO")
        XCTAssertEqual(findings[0].utf16Range, NSRange(location: 2, length: 1))
    }

    func testRespectsMaxFindingsAndMaxCharactersBounds() {
        let text = String(repeating: "\u{200B}a", count: 50)
        let cappedByFindings = TrojanSourceScanner.scan(text, maxFindings: 5, maxCharacters: 1000)
        XCTAssertEqual(cappedByFindings.count, 5)

        let cappedByChars = TrojanSourceScanner.scan(text, maxFindings: 100, maxCharacters: 6)
        XCTAssertEqual(cappedByChars.count, 3)
    }
}

import Foundation
import XCTest
@testable import KadmosCore

final class LineColumnTests: XCTestCase {
    func testEmptyTextPositionOffsetAndStats() {
        let ns = "" as NSString
        let pos = LineColumnCalculator.position(in: ns, utf16Location: 0)
        XCTAssertEqual(pos.line, 1)
        XCTAssertEqual(pos.column, 1)

        XCTAssertEqual(LineColumnCalculator.utf16Offset(forLine: 1, in: ns), 0)
        XCTAssertNil(LineColumnCalculator.utf16Offset(forLine: 2, in: ns))
        XCTAssertNil(LineColumnCalculator.utf16Offset(forLine: 0, in: ns))

        let stats = LineColumnCalculator.stats(for: "", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(stats, DocumentStats(lineCount: 1, characterCount: 0, wordCount: 0, selectedCharacterCount: 0))
    }

    func testMultiLineLFAndTrailingNewline() {
        let text = "alpha\nbeta\n"
        let ns = text as NSString

        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 0).line, 1)
        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 0).column, 1)

        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 5).line, 1)
        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 5).column, 6)

        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 6).line, 2)
        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 6).column, 1)

        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 11).line, 3)
        XCTAssertEqual(LineColumnCalculator.position(in: ns, utf16Location: 11).column, 1)

        XCTAssertEqual(LineColumnCalculator.utf16Offset(forLine: 1, in: ns), 0)
        XCTAssertEqual(LineColumnCalculator.utf16Offset(forLine: 2, in: ns), 6)
        XCTAssertEqual(LineColumnCalculator.utf16Offset(forLine: 3, in: ns), 11)
        XCTAssertNil(LineColumnCalculator.utf16Offset(forLine: 4, in: ns))
    }

    func testCRLFAndCRLineEndings() {
        let text = "a\r\nb\rc"
        let ns = text as NSString

        XCTAssertEqual(LineColumnCalculator.utf16Offset(forLine: 1, in: ns), 0)
        XCTAssertEqual(LineColumnCalculator.utf16Offset(forLine: 2, in: ns), 3)
        XCTAssertEqual(LineColumnCalculator.utf16Offset(forLine: 3, in: ns), 5)

        let posLine2 = LineColumnCalculator.position(in: ns, utf16Location: 3)
        XCTAssertEqual(posLine2.line, 2)
        XCTAssertEqual(posLine2.column, 1)

        let posLine3 = LineColumnCalculator.position(in: ns, utf16Location: 6)
        XCTAssertEqual(posLine3.line, 3)
        XCTAssertEqual(posLine3.column, 2)

        let stats = LineColumnCalculator.stats(for: text, selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(stats.lineCount, 3)
        XCTAssertEqual(stats.wordCount, 3)
    }

    func testSurrogatePairOffsetsClampingAndStats() {
        let text = "🚀 Merhaba dünya!\nİkinci satır."
        let ns = text as NSString

        // '🚀' is 2 UTF-16 units; 'M' starts at offset 3
        let posM = LineColumnCalculator.position(in: ns, utf16Location: 3)
        XCTAssertEqual(posM.line, 1)
        XCTAssertEqual(posM.column, 4)

        // Clamping negative and excessive locations
        let clampedNeg = LineColumnCalculator.position(in: ns, utf16Location: -10)
        XCTAssertEqual(clampedNeg.line, 1)
        XCTAssertEqual(clampedNeg.column, 1)

        let clampedEnd = LineColumnCalculator.position(in: ns, utf16Location: 99_999)
        XCTAssertEqual(clampedEnd.line, 2)
        XCTAssertEqual(clampedEnd.column, 14)

        // Selecting "🚀" (UTF-16 length 2) counts as 1 character
        let stats = LineColumnCalculator.stats(for: text, selectedRange: NSRange(location: 0, length: 2))
        XCTAssertEqual(stats.lineCount, 2)
        XCTAssertEqual(stats.wordCount, 4)
        XCTAssertEqual(stats.selectedCharacterCount, 1)
        XCTAssertEqual(stats.characterCount, text.count)

        // Out-of-bounds selection does not crash
        let safeStats = LineColumnCalculator.stats(for: text, selectedRange: NSRange(location: 500, length: 20))
        XCTAssertEqual(safeStats.selectedCharacterCount, 0)
    }
}

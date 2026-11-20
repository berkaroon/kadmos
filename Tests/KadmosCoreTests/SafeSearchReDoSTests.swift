import Foundation
import XCTest
@testable import KadmosCore

final class SafeSearchReDoSTests: XCTestCase {
    func testPlainSearchCaseSensitivityAndWholeWord() {
        let text = "foo Foo foobar foo_bar bar_foo (foo)"

        let insensitive = SafeSearchEngine.findAllPlain(
            query: "foo",
            in: text,
            options: SearchOptions(caseSensitive: false, wholeWord: false)
        )
        XCTAssertEqual(insensitive.count, 6)

        let sensitiveWholeWord = SafeSearchEngine.findAllPlain(
            query: "foo",
            in: text,
            options: SearchOptions(caseSensitive: true, wholeWord: true)
        )
        XCTAssertEqual(sensitiveWholeWord.count, 2)
        XCTAssertEqual(sensitiveWholeWord[0], NSRange(location: 0, length: 3))
        XCTAssertEqual(sensitiveWholeWord[1], NSRange(location: text.utf16.count - 4, length: 3))
    }

    func testNextAndPreviousMatchNavigationWithAndWithoutWrap() {
        let matches = [
            NSRange(location: 2, length: 3),
            NSRange(location: 10, length: 3),
            NSRange(location: 20, length: 3)
        ]

        XCTAssertEqual(SafeSearchEngine.nextMatchIndex(in: matches, from: 0, wrapAround: false), 0)
        XCTAssertEqual(SafeSearchEngine.nextMatchIndex(in: matches, from: 5, wrapAround: false), 1)
        XCTAssertNil(SafeSearchEngine.nextMatchIndex(in: matches, from: 25, wrapAround: false))
        XCTAssertEqual(SafeSearchEngine.nextMatchIndex(in: matches, from: 25, wrapAround: true), 0)

        XCTAssertEqual(SafeSearchEngine.previousMatchIndex(in: matches, before: 20, wrapAround: false), 1)
        XCTAssertEqual(SafeSearchEngine.previousMatchIndex(in: matches, before: 12, wrapAround: false), 1)
        XCTAssertNil(SafeSearchEngine.previousMatchIndex(in: matches, before: 2, wrapAround: false))
        XCTAssertEqual(SafeSearchEngine.previousMatchIndex(in: matches, before: 2, wrapAround: true), 2)
    }

    func testReplacingMatchAndReplacingAllWithRegexCaptures() async {
        let input = "id=12, id=345"
        let opts = SearchOptions(caseSensitive: true, wholeWord: false, isRegex: true)
        let outcome = await SafeSearchEngine.findAll(query: "id=(\\d+)", in: input, options: opts)
        guard case .matches(let ranges) = outcome else {
            return XCTFail("Expected regex matches")
        }
        XCTAssertEqual(ranges.count, 2)

        let singleReplaced = SafeSearchEngine.replacingMatch(
            in: input,
            range: ranges[0],
            with: "[$1]",
            query: "id=(\\d+)",
            options: opts
        )
        XCTAssertEqual(singleReplaced, "[12], id=345")

        let replaceAllOutcome = await SafeSearchEngine.replacingAll(
            query: "id=(\\d+)",
            in: input,
            with: "[$1]",
            options: opts
        )
        XCTAssertEqual(replaceAllOutcome, .replaced(text: "[12], [345]", count: 2))
    }

    func testInvalidRegexReturnsInvalidRegexError() async {
        let outcome = await SafeSearchEngine.findAll(
            query: "[unclosed",
            in: "hello",
            options: SearchOptions(isRegex: true)
        )
        if case .invalidRegex(let message) = outcome {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected invalidRegex, got \(outcome)")
        }
    }

    func testCatastrophicBacktrackingReDoSTimesOutPromptly() async {
        let evilInput = String(repeating: "a", count: 40) + "X"
        let opts = SearchOptions(caseSensitive: true, wholeWord: false, isRegex: true)

        let start = Date()
        let outcome = await SafeSearchEngine.findAll(
            query: "^(a+)+$",
            in: evilInput,
            options: opts,
            timeoutSeconds: 0.2
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, 1.0)

        let replaceStart = Date()
        let replaceOutcome = await SafeSearchEngine.replacingAll(
            query: "^(a+)+$",
            in: evilInput,
            with: "safe",
            options: opts,
            timeoutSeconds: 0.2
        )
        let replaceElapsed = Date().timeIntervalSince(replaceStart)

        XCTAssertEqual(replaceOutcome, .timedOut)
        XCTAssertLessThan(replaceElapsed, 1.0)
    }

    func testRegexTaskCancellationStopsPromptly() async {
        let evilInput = String(repeating: "a", count: 40) + "X"
        let opts = SearchOptions(caseSensitive: true, wholeWord: false, isRegex: true)

        let task = Task {
            await SafeSearchEngine.findAll(
                query: "^(a+)+$",
                in: evilInput,
                options: opts,
                timeoutSeconds: 10.0
            )
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let cancelTime = Date()
        task.cancel()
        let result = await task.value
        let elapsedAfterCancel = Date().timeIntervalSince(cancelTime)

        XCTAssertEqual(result, .matches([]))
        XCTAssertLessThan(elapsedAfterCancel, 1.0)
    }
}

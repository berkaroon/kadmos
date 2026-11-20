import Foundation

/// Options controlling find and replace behavior.
public struct SearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var isRegex: Bool
    public var wrapAround: Bool

    public init(
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        isRegex: Bool = false,
        wrapAround: Bool = true
    ) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.isRegex = isRegex
        self.wrapAround = wrapAround
    }
}

/// Outcome of a bounded, ReDoS-safe search operation.
public enum SearchOutcome: Equatable, Sendable {
    case matches([NSRange])
    case invalidRegex(String)
    case timedOut
}

/// Outcome of a bounded, ReDoS-safe replace-all operation.
public enum ReplaceAllOutcome: Equatable, Sendable {
    case replaced(text: String, count: Int)
    case invalidRegex(String)
    case timedOut
}

/// Search and replace engine enforcing execution deadlines and cancellation (`SECURITY.md` §3.5).
public enum SafeSearchEngine: Sendable {
    public static let defaultTimeoutSeconds: TimeInterval = 1.5
    public static let defaultMaxMatches: Int = 50_000

    /// Runs a find-all search on a background task, aborting regex backtracking via
    /// `.reportProgress` if `timeoutSeconds` expires or the task is cancelled.
    public static func findAll(
        query: String,
        in text: String,
        options: SearchOptions,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        maxMatches: Int = defaultMaxMatches
    ) async -> SearchOutcome {
        guard !query.isEmpty, maxMatches > 0 else {
            return .matches([])
        }

        if !options.isRegex {
            return await Task.detached(priority: .userInitiated) {
                if Task.isCancelled {
                    return .matches([])
                }
                let ranges = findAllPlain(
                    query: query,
                    in: text,
                    options: options,
                    maxMatches: maxMatches
                )
                return .matches(ranges)
            }.value
        }

        let regex: NSRegularExpression
        do {
            regex = try compileRegex(query: query, options: options)
        } catch {
            return .invalidRegex(error.localizedDescription)
        }

        let boundedTimeout = max(0.01, timeoutSeconds)
        let workerTask = Task.detached(priority: .userInitiated) { () -> SearchOutcome in
            let deadline = Date().addingTimeInterval(boundedTimeout)
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            var matches: [NSRange] = []
            var didTimeout = false
            var wasCancelled = false

            regex.enumerateMatches(
                in: text,
                options: [.reportProgress],
                range: fullRange
            ) { result, _, stop in
                if Task.isCancelled {
                    wasCancelled = true
                    stop.pointee = true
                    return
                }
                if Date() >= deadline {
                    didTimeout = true
                    stop.pointee = true
                    return
                }
                if let match = result {
                    matches.append(match.range)
                    if matches.count >= maxMatches {
                        stop.pointee = true
                    }
                }
            }

            if wasCancelled {
                return .matches([])
            }
            if didTimeout {
                KadmosLogger.warning(.search, message: "Regex search timed out and was aborted")
                return .timedOut
            }
            return .matches(matches)
        }

        return await withTaskCancellationHandler {
            await workerTask.value
        } onCancel: {
            workerTask.cancel()
        }
    }

    /// Synchronous plain-text search suitable for instant typing feedback when regex mode is disabled.
    public static func findAllPlain(
        query: String,
        in text: String,
        options: SearchOptions,
        maxMatches: Int = defaultMaxMatches
    ) -> [NSRange] {
        guard !query.isEmpty, maxMatches > 0 else {
            return []
        }

        let nsText = text as NSString
        let textLength = nsText.length
        guard textLength > 0 else {
            return []
        }

        let compareOptions: NSString.CompareOptions = options.caseSensitive ? [.literal] : [.caseInsensitive]
        var matches: [NSRange] = []
        var searchLocation = 0

        let queryScalars = query.unicodeScalars
        let checkLeadingBoundary = options.wholeWord && (queryScalars.first.map(isWordScalar) ?? false)
        let checkTrailingBoundary = options.wholeWord && (queryScalars.last.map(isWordScalar) ?? false)

        while searchLocation <= textLength && matches.count < maxMatches {
            let searchRange = NSRange(location: searchLocation, length: textLength - searchLocation)
            let found = nsText.range(of: query, options: compareOptions, range: searchRange)
            guard found.location != NSNotFound else {
                break
            }

            let passesBoundary: Bool
            if options.wholeWord {
                passesBoundary = satisfiesWordBoundaries(
                    in: text,
                    nsText: nsText,
                    matchRange: found,
                    checkLeading: checkLeadingBoundary,
                    checkTrailing: checkTrailingBoundary
                )
            } else {
                passesBoundary = true
            }

            if passesBoundary {
                matches.append(found)
            }

            let advanceBy = max(1, found.length)
            searchLocation = found.location + advanceBy
        }

        return matches
    }

    /// Returns the index of the next match at or after `cursorLocation`, wrapping if requested.
    public static func nextMatchIndex(
        in matches: [NSRange],
        from cursorLocation: Int,
        wrapAround: Bool
    ) -> Int? {
        guard !matches.isEmpty else {
            return nil
        }

        // Binary search for the first match with location >= cursorLocation.
        var low = 0
        var high = matches.count
        while low < high {
            let mid = low + (high - low) / 2
            if matches[mid].location < cursorLocation {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low < matches.count {
            return low
        }
        return wrapAround ? 0 : nil
    }

    /// Returns the index of the previous match strictly before `cursorLocation`, wrapping if requested.
    public static func previousMatchIndex(
        in matches: [NSRange],
        before cursorLocation: Int,
        wrapAround: Bool
    ) -> Int? {
        guard !matches.isEmpty else {
            return nil
        }

        // Binary search for the last match with location < cursorLocation.
        var low = 0
        var high = matches.count
        while low < high {
            let mid = low + (high - low) / 2
            if matches[mid].location < cursorLocation {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let candidate = low - 1
        if candidate >= 0 {
            return candidate
        }
        return wrapAround ? (matches.count - 1) : nil
    }

    /// Replaces a single validated match range in `text`, evaluating regex capture templates when `options.isRegex` is enabled.
    public static func replacingMatch(
        in text: String,
        range: NSRange,
        with replacement: String,
        query: String? = nil,
        options: SearchOptions = SearchOptions()
    ) -> String? {
        let nsText = text as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= nsText.length else {
            return nil
        }

        if options.isRegex, let query, !query.isEmpty {
            guard let regex = try? compileRegex(query: query, options: options),
                  let match = regex.firstMatch(in: text, options: [], range: range) else {
                return nil
            }
            let expanded = regex.replacementString(
                for: match,
                in: text,
                offset: 0,
                template: replacement
            )
            return nsText.replacingCharacters(in: range, with: expanded)
        }

        return nsText.replacingCharacters(in: range, with: replacement)
    }

    /// Synchronously replaces a sorted list of non-overlapping match ranges in O(N) time.
    public static func replacingMatches(
        in text: String,
        ranges: [NSRange],
        with replacement: String
    ) -> String {
        guard !ranges.isEmpty else {
            return text
        }

        let nsText = text as NSString
        let result = NSMutableString(capacity: nsText.length)
        var cursor = 0

        for range in ranges {
            guard range.location != NSNotFound,
                  range.location >= cursor,
                  range.location + range.length <= nsText.length else {
                continue
            }
            if range.location > cursor {
                result.append(nsText.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            result.append(replacement)
            cursor = range.location + range.length
        }

        if cursor < nsText.length {
            result.append(nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)))
        }

        return result as String
    }

    /// Replaces all matches using the bounded, ReDoS-safe search engine.
    public static func replacingAll(
        query: String,
        in text: String,
        with replacement: String,
        options: SearchOptions,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        maxMatches: Int = defaultMaxMatches
    ) async -> ReplaceAllOutcome {
        guard !query.isEmpty, maxMatches > 0 else {
            return .replaced(text: text, count: 0)
        }

        if !options.isRegex {
            let outcome = await findAll(
                query: query,
                in: text,
                options: options,
                timeoutSeconds: timeoutSeconds,
                maxMatches: maxMatches
            )
            switch outcome {
            case .matches(let ranges):
                let updated = replacingMatches(in: text, ranges: ranges, with: replacement)
                return .replaced(text: updated, count: ranges.count)
            case .invalidRegex(let msg):
                return .invalidRegex(msg)
            case .timedOut:
                return .timedOut
            }
        }

        let regex: NSRegularExpression
        do {
            regex = try compileRegex(query: query, options: options)
        } catch {
            return .invalidRegex(error.localizedDescription)
        }

        let boundedTimeout = max(0.01, timeoutSeconds)
        let workerTask = Task.detached(priority: .userInitiated) { () -> ReplaceAllOutcome in
            let deadline = Date().addingTimeInterval(boundedTimeout)
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let output = NSMutableString(capacity: nsText.length)
            var cursor = 0
            var count = 0
            var didTimeout = false
            var wasCancelled = false

            regex.enumerateMatches(
                in: text,
                options: [.reportProgress],
                range: fullRange
            ) { result, _, stop in
                if Task.isCancelled {
                    wasCancelled = true
                    stop.pointee = true
                    return
                }
                if Date() >= deadline {
                    didTimeout = true
                    stop.pointee = true
                    return
                }
                guard let match = result else {
                    return
                }
                let range = match.range
                guard range.location >= cursor, range.location + range.length <= nsText.length else {
                    return
                }
                if range.location > cursor {
                    output.append(nsText.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                }
                let expanded = regex.replacementString(for: match, in: text, offset: 0, template: replacement)
                output.append(expanded)
                cursor = range.location + range.length
                count += 1
                if count >= maxMatches {
                    stop.pointee = true
                }
            }

            if wasCancelled {
                return .replaced(text: text, count: 0)
            }
            if didTimeout {
                KadmosLogger.warning(.search, message: "Regex replace-all timed out and was aborted")
                return .timedOut
            }
            if cursor < nsText.length {
                output.append(nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)))
            }
            return .replaced(text: output as String, count: count)
        }

        return await withTaskCancellationHandler {
            await workerTask.value
        } onCancel: {
            workerTask.cancel()
        }
    }

    // MARK: - Regex & Word Boundary Helpers

    private static func compileRegex(query: String, options: SearchOptions) throws -> NSRegularExpression {
        let effectivePattern = options.wholeWord ? "\\b(?:\(query))\\b" : query
        var regexOptions: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive {
            regexOptions.insert(.caseInsensitive)
        }
        return try NSRegularExpression(pattern: effectivePattern, options: regexOptions)
    }

    private static func satisfiesWordBoundaries(
        in text: String,
        nsText: NSString,
        matchRange: NSRange,
        checkLeading: Bool,
        checkTrailing: Bool
    ) -> Bool {
        if checkLeading, matchRange.location > 0 {
            if let scalarBefore = scalarImmediatelyBefore(utf16Offset: matchRange.location, in: text, nsText: nsText),
               isWordScalar(scalarBefore) {
                return false
            }
        }
        if checkTrailing {
            let endOffset = matchRange.location + matchRange.length
            if endOffset < nsText.length,
               let scalarAfter = scalarImmediatelyAt(utf16Offset: endOffset, in: text, nsText: nsText),
               isWordScalar(scalarAfter) {
                return false
            }
        }
        return true
    }

    private static func scalarImmediatelyBefore(
        utf16Offset: Int,
        in text: String,
        nsText: NSString
    ) -> UnicodeScalar? {
        guard utf16Offset > 0 else { return nil }
        let idx16 = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        if let scalarIdx = idx16.samePosition(in: text.unicodeScalars),
           scalarIdx > text.unicodeScalars.startIndex {
            return text.unicodeScalars[text.unicodeScalars.index(before: scalarIdx)]
        }
        let unit = nsText.character(at: utf16Offset - 1)
        return UnicodeScalar(unit)
    }

    private static func scalarImmediatelyAt(
        utf16Offset: Int,
        in text: String,
        nsText: NSString
    ) -> UnicodeScalar? {
        guard utf16Offset < nsText.length else { return nil }
        let idx16 = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        if let scalarIdx = idx16.samePosition(in: text.unicodeScalars),
           scalarIdx < text.unicodeScalars.endIndex {
            return text.unicodeScalars[scalarIdx]
        }
        let unit = nsText.character(at: utf16Offset)
        return UnicodeScalar(unit)
    }

    private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x5F || CharacterSet.alphanumerics.contains(scalar)
    }
}

import Foundation

/// Errors raised by Kadmos document security checks and bounded I/O operations.
public enum DocumentSecurityError: Error, LocalizedError, Equatable, Sendable {
    case notARegularFile
    case failedToOpenFile(message: String)
    case failedToStatFile(errno: Int32)
    case failedToReadFile(message: String)
    case fileExceededBoundedReadLimit
    case pathOutsideAllowedScope
    case invalidByteOffset
    case failedToSaveFile(message: String)

    public var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "Target is not a regular file."
        case .failedToOpenFile(let message):
            return "Failed to open file: \(message)"
        case .failedToStatFile(let errno):
            return "Failed to inspect opened file descriptor (errno \(errno))."
        case .failedToReadFile(let message):
            return "Failed to read file: \(message)"
        case .fileExceededBoundedReadLimit:
            return "File grew beyond bounded in-memory size limit during read."
        case .pathOutsideAllowedScope:
            return "Resolved file path escapes the allowed directory scope."
        case .invalidByteOffset:
            return "Requested streaming byte offset is out of range."
        case .failedToSaveFile(let message):
            return "Failed to save file atomically: \(message)"
        }
    }
}

/// Memory safety tier assigned when opening a file (`SECURITY.md` §3.5).
public enum LargeFileTier: Equatable, Sendable {
    case normal
    case limitedMode(byteSize: Int64)
    case streamingReadOnly(byteSize: Int64)
}

/// Result of opening a document safely via `DocumentSecurity.openDocument(at:)`.
public struct OpenedDocumentPayload: Sendable {
    public let canonicalURL: URL
    public let wasSymlink: Bool
    public let byteSize: Int64
    public let tier: LargeFileTier
    public let decoded: DecodedTextResult?
    public let detectedLineEnding: KadmosLineEnding
    public let streamingReader: StreamingFileReader?

    public init(
        canonicalURL: URL,
        wasSymlink: Bool,
        byteSize: Int64,
        tier: LargeFileTier,
        decoded: DecodedTextResult?,
        detectedLineEnding: KadmosLineEnding,
        streamingReader: StreamingFileReader?
    ) {
        self.canonicalURL = canonicalURL
        self.wasSymlink = wasSymlink
        self.byteSize = byteSize
        self.tier = tier
        self.decoded = decoded
        self.detectedLineEnding = detectedLineEnding
        self.streamingReader = streamingReader
    }
}

/// Actor-isolated, UTF-8-boundary-aware streaming reader for files exceeding 1 GB (`SECURITY.md` §3.5).
public actor StreamingFileReader {
    public nonisolated let url: URL
    public nonisolated let totalBytes: Int64
    public nonisolated let chunkSize: Int

    public init(url: URL, totalBytes: Int64, chunkSize: Int = 262_144) {
        self.url = url
        self.totalBytes = max(0, totalBytes)
        self.chunkSize = max(4, chunkSize)
    }

    /// Reads a UTF-8 chunk near `offset`, snapping boundaries so multi-byte characters are not split.
    public func readChunk(atOffset offset: Int64) throws -> (
        text: String,
        nextOffset: Int64,
        prevOffset: Int64,
        actualStart: Int64,
        actualEnd: Int64,
        hadInvalidSequences: Bool
    ) {
        guard offset >= 0 else {
            throw DocumentSecurityError.invalidByteOffset
        }

        if totalBytes == 0 {
            guard offset == 0 else {
                throw DocumentSecurityError.invalidByteOffset
            }
            return ("", 0, 0, 0, 0, false)
        }

        guard offset <= totalBytes else {
            throw DocumentSecurityError.invalidByteOffset
        }

        let (handle, effectiveTotal) = try DocumentSecurity.openRegularFileHandle(at: url)
        defer { try? handle.close() }
        if offset == effectiveTotal {
            let prev = max(0, effectiveTotal - Int64(chunkSize))
            return ("", effectiveTotal, prev, effectiveTotal, effectiveTotal, false)
        }
        guard offset < effectiveTotal else {
            throw DocumentSecurityError.invalidByteOffset
        }

        let actualStart = try snapStartToUTF8Boundary(offset: offset, handle: handle)

        let nominalEnd = min(effectiveTotal, actualStart + Int64(chunkSize))
        let maxReadEnd = min(effectiveTotal, nominalEnd + 3)
        let bytesToRead = Int(maxReadEnd - actualStart)

        let buffer: Data
        do {
            try handle.seek(toOffset: UInt64(actualStart))
            buffer = try handle.read(upToCount: bytesToRead) ?? Data()
        } catch {
            throw DocumentSecurityError.failedToReadFile(message: error.localizedDescription)
        }

        let nominalSliceCount = min(buffer.count, Int(nominalEnd - actualStart))
        let actualSliceCount: Int
        if nominalEnd >= effectiveTotal || nominalSliceCount >= buffer.count {
            actualSliceCount = buffer.count
        } else {
            actualSliceCount = snapEndToUTF8Boundary(buffer: buffer, nominalCount: nominalSliceCount)
        }

        let chunkData = Data(buffer.prefix(actualSliceCount))
        let actualEnd = actualStart + Int64(actualSliceCount)
        let decoded = TextEncodingCodec.decode(chunkData, as: .utf8)
        let prevOffset = max(0, actualStart - Int64(chunkSize))

        return (
            text: decoded.text,
            nextOffset: actualEnd,
            prevOffset: prevOffset,
            actualStart: actualStart,
            actualEnd: actualEnd,
            hadInvalidSequences: decoded.hadInvalidSequences
        )
    }

    private func snapStartToUTF8Boundary(offset: Int64, handle: FileHandle) throws -> Int64 {
        guard offset > 0 else {
            return 0
        }
        let probeStart = max(0, offset - 3)
        let probeLength = Int(offset - probeStart) + 1
        let probeData: Data
        do {
            try handle.seek(toOffset: UInt64(probeStart))
            probeData = try handle.read(upToCount: probeLength) ?? Data()
        } catch {
            throw DocumentSecurityError.failedToReadFile(message: error.localizedDescription)
        }

        guard probeData.count == probeLength else {
            return offset
        }

        let bytes = Array(probeData)
        let targetByte = bytes[bytes.count - 1]
        guard Self.isUTF8Continuation(targetByte) else {
            return offset
        }

        // Look back up to 3 bytes for a valid leading byte whose span covers `offset`.
        var idx = bytes.count - 2
        while idx >= 0 {
            let candidate = bytes[idx]
            if Self.isUTF8Continuation(candidate) {
                idx -= 1
                continue
            }
            if let expectedLen = Self.expectedUTF8SequenceLength(leadingByte: candidate) {
                let distance = (bytes.count - 1) - idx
                if distance < expectedLen {
                    return probeStart + Int64(idx)
                }
            }
            break
        }

        return offset
    }

    private func snapEndToUTF8Boundary(buffer: Data, nominalCount: Int) -> Int {
        guard nominalCount > 0 else {
            return 0
        }
        let bytes = Array(buffer)
        let lastByte = bytes[nominalCount - 1]
        if lastByte < 0x80 {
            return nominalCount
        }

        // Scan up to 3 bytes backward from nominalCount - 1 to locate the leading byte.
        let searchFloor = max(0, nominalCount - 4)
        var leadIndex = nominalCount - 1
        while leadIndex >= searchFloor && Self.isUTF8Continuation(bytes[leadIndex]) {
            leadIndex -= 1
        }

        guard leadIndex >= searchFloor,
              let expectedLen = Self.expectedUTF8SequenceLength(leadingByte: bytes[leadIndex]) else {
            return nominalCount
        }

        let neededEnd = leadIndex + expectedLen
        if neededEnd > nominalCount && neededEnd <= bytes.count {
            let allContinuations = (nominalCount..<neededEnd).allSatisfy { Self.isUTF8Continuation(bytes[$0]) }
            if allContinuations {
                return neededEnd
            }
        }

        return nominalCount
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (byte & 0xC0) == 0x80
    }

    private static func expectedUTF8SequenceLength(leadingByte: UInt8) -> Int? {
        switch leadingByte {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }
}

/// Security primitives for path canonicalization, scope validation, TOCTOU-safe opens, and atomic saves.
public enum DocumentSecurity: Sendable {
    public static let limitedModeBytes: Int64 = 50 * 1024 * 1024
    public static let streamingModeBytes: Int64 = 1024 * 1024 * 1024

    private static let maxSymlinkHops = 40
    private static let systemFirmlinkRoots: Set<String> = ["/var", "/tmp", "/etc"]

    /// Resolves symlinks and `..` traversal components cleanly, including non-existent leaf paths
    /// and broken symlinks.
    public static func resolveCanonicalURL(_ url: URL) -> (resolved: URL, wasSymlink: Bool) {
        let rawPath = url.path.hasPrefix("/") ? url.path : url.standardizedFileURL.path
        var queue = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var resolvedComponents: [String] = []
        var wasSymlink = false
        var symlinkHops = 0

        while !queue.isEmpty {
            let component = queue.removeFirst()
            if component == "." || component.isEmpty {
                continue
            }
            if component == ".." {
                if !resolvedComponents.isEmpty {
                    resolvedComponents.removeLast()
                }
                continue
            }

            resolvedComponents.append(component)
            let currentPath = "/" + resolvedComponents.joined(separator: "/")

            if systemFirmlinkRoots.contains(currentPath) {
                continue
            }

            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: currentPath) {
                symlinkHops += 1
                if symlinkHops > maxSymlinkHops {
                    let loopURL = URL(fileURLWithPath: currentPath).standardizedFileURL
                    return (loopURL, true)
                }
                wasSymlink = true

                let destComponents = destination
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)
                if destination.hasPrefix("/") {
                    resolvedComponents.removeAll()
                } else {
                    resolvedComponents.removeLast()
                }
                queue.insert(contentsOf: destComponents, at: 0)
            }
        }

        let canonicalPath = resolvedComponents.isEmpty ? "/" : "/" + resolvedComponents.joined(separator: "/")
        let finalURL = URL(fileURLWithPath: canonicalPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return (finalURL, wasSymlink)
    }

    /// Ensures `candidate` resolves inside (or equal to) `allowedRoot` after resolving symlinks and `..`.
    ///
    /// Guards directory boundary checks so sibling paths such as `/tmp/root2` do not match `/tmp/root`.
    public static func validateWithinScope(candidate: URL, allowedRoot: URL) -> Bool {
        guard candidate.isFileURL, allowedRoot.isFileURL else {
            return false
        }

        let (resolvedCandidate, _) = resolveCanonicalURL(candidate)
        let (resolvedRoot, _) = resolveCanonicalURL(allowedRoot)

        let candidatePath = trimmedDirectoryPath(resolvedCandidate.path)
        let rootPath = trimmedDirectoryPath(resolvedRoot.path)

        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// Classifies a byte size into `normal`, `limitedMode`, or `streamingReadOnly`.
    public static func classifyTier(
        byteSize: Int64,
        limitedThreshold: Int64 = limitedModeBytes,
        streamingThreshold: Int64 = streamingModeBytes
    ) -> LargeFileTier {
        if byteSize > streamingThreshold {
            return .streamingReadOnly(byteSize: byteSize)
        }
        if byteSize > limitedThreshold {
            return .limitedMode(byteSize: byteSize)
        }
        return .normal
    }

    /// Directly opens a file without a `fileExists` pre-check (TOCTOU-safe), checks `fstat` regular-file
    /// status, classifies large-file tier, and decodes bounded files into LF-normalized editor text.
    public static func openDocument(
        at url: URL,
        overrideEncoding: KadmosTextEncoding? = nil,
        limitedThreshold: Int64 = limitedModeBytes,
        streamingThreshold: Int64 = streamingModeBytes
    ) throws -> OpenedDocumentPayload {
        let (resolved, wasSymlink) = resolveCanonicalURL(url)
        if wasSymlink {
            KadmosLogger.warningPath(.security, message: "Opening document via symlink", path: resolved.path)
        }

        let (handle, byteSize) = try openRegularFileHandle(at: resolved)
        defer { try? handle.close() }

        let tier = classifyTier(
            byteSize: byteSize,
            limitedThreshold: limitedThreshold,
            streamingThreshold: streamingThreshold
        )

        if case .streamingReadOnly = tier {
            let reader = StreamingFileReader(url: resolved, totalBytes: byteSize)
            KadmosLogger.infoPath(.document, message: "Opened document in streaming read-only tier", path: resolved.path)
            return OpenedDocumentPayload(
                canonicalURL: resolved,
                wasSymlink: wasSymlink,
                byteSize: byteSize,
                tier: tier,
                decoded: nil,
                detectedLineEnding: .lf,
                streamingReader: reader
            )
        }

        let maxBoundedBytes = Int(min(Int64(Int.max - 1), streamingThreshold))
        let data: Data
        do {
            data = try handle.read(upToCount: maxBoundedBytes + 1) ?? Data()
        } catch {
            throw DocumentSecurityError.failedToReadFile(message: error.localizedDescription)
        }

        if Int64(data.count) > streamingThreshold {
            throw DocumentSecurityError.fileExceededBoundedReadLimit
        }

        let rawDecoded: DecodedTextResult
        if let overrideEncoding {
            rawDecoded = TextEncodingCodec.decode(data, as: overrideEncoding)
        } else {
            rawDecoded = TextEncodingCodec.detectAndDecode(data)
        }
        let detectedLineEnding = LineEndingCodec.detect(in: rawDecoded.text)
        let normalizedText = LineEndingCodec.normalizeToLF(rawDecoded.text)
        let editorDecoded = DecodedTextResult(
            text: normalizedText,
            encoding: rawDecoded.encoding,
            hadInvalidSequences: rawDecoded.hadInvalidSequences,
            invalidSequenceCount: rawDecoded.invalidSequenceCount
        )

        KadmosLogger.infoPath(.document, message: "Opened document", path: resolved.path)
        return OpenedDocumentPayload(
            canonicalURL: resolved,
            wasSymlink: wasSymlink,
            byteSize: Int64(data.count),
            tier: tier,
            decoded: editorDecoded,
            detectedLineEnding: detectedLineEnding,
            streamingReader: nil
        )
    }

    /// Atomically saves `data` to the canonical path of `url`, never leaving `+x` execute bits set (`SECURITY.md` §3.4).
    public static func atomicSave(data: Data, to url: URL) throws {
        let (targetURL, wasSymlink) = resolveCanonicalURL(url)
        if wasSymlink {
            KadmosLogger.warningPath(.security, message: "Saving to resolved symlink target", path: targetURL.path)
        }

        var st = stat()
        var targetPermissions: Int = 0o644
        if lstat(targetURL.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw DocumentSecurityError.notARegularFile
            }
            let existingMode = Int(st.st_mode & 0o777)
            targetPermissions = existingMode & ~0o111
        }

        do {
            try data.write(to: targetURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: targetPermissions)],
                ofItemAtPath: targetURL.path
            )
            KadmosLogger.infoPath(.document, message: "Saved document atomically", path: targetURL.path)
        } catch {
            KadmosLogger.errorPath(.document, message: "Failed atomic save", path: targetURL.path, error: error)
            throw DocumentSecurityError.failedToSaveFile(message: error.localizedDescription)
        }
    }

    /// Opens `url` directly with `O_RDONLY | O_NONBLOCK` and verifies `fstat` regular-file status.
    internal static func openRegularFileHandle(at url: URL) throws -> (handle: FileHandle, byteSize: Int64) {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            let err = errno
            let message = String(cString: strerror(err))
            KadmosLogger.errorPath(.document, message: "Failed to open document directly", path: url.path)
            throw DocumentSecurityError.failedToOpenFile(message: message)
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw DocumentSecurityError.failedToStatFile(errno: err)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            KadmosLogger.warningPath(.security, message: "Rejected non-regular file open", path: url.path)
            throw DocumentSecurityError.notARegularFile
        }

        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), Int64(st.st_size))
    }

    private static func trimmedDirectoryPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else {
            return path
        }
        return String(path.dropLast())
    }
}

import Foundation
import Synchronization

/// Errors raised by `SessionVault` operations.
public enum SessionVaultError: Error, LocalizedError, Equatable, Sendable {
    case invalidDraftFilename
    case fileOutsideVaultScope
    case symlinkDetectedInVault

    public var errorDescription: String? {
        switch self {
        case .invalidDraftFilename:
            return "Invalid session draft filename."
        case .fileOutsideVaultScope:
            return "Session file path escapes the SessionVault directory."
        case .symlinkDetectedInVault:
            return "Refused to read or write through a symlink inside SessionVault."
        }
    }
}

/// Persistable snapshot of an individual editor tab.
public struct SessionTabSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let filePath: String?
    public let bookmarkData: Data?
    public let untitledNumber: Int?
    public let encoding: KadmosTextEncoding
    public let lineEnding: KadmosLineEnding
    public let isDirty: Bool
    public let cursorLocation: Int
    public let zoomPercent: Int
    public let draftFilename: String?
    public let customFilename: String?

    public init(
        id: UUID,
        filePath: String? = nil,
        bookmarkData: Data? = nil,
        untitledNumber: Int? = nil,
        encoding: KadmosTextEncoding = .utf8,
        lineEnding: KadmosLineEnding = .lf,
        isDirty: Bool = false,
        cursorLocation: Int = 0,
        zoomPercent: Int = 100,
        draftFilename: String? = nil,
        customFilename: String? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.bookmarkData = bookmarkData
        self.untitledNumber = untitledNumber
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.isDirty = isDirty
        self.cursorLocation = cursorLocation
        self.zoomPercent = zoomPercent
        self.draftFilename = draftFilename
        self.customFilename = customFilename
    }
}

/// Persistable snapshot of the entire editor session.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let activeTabID: UUID?
    public let tabs: [SessionTabSnapshot]
    public let savedAt: Date

    public init(activeTabID: UUID?, tabs: [SessionTabSnapshot], savedAt: Date = Date()) {
        self.activeTabID = activeTabID
        self.tabs = tabs
        self.savedAt = savedAt
    }
}

/// Manages session metadata (`session.json`) and unsaved draft buffers (`draft-<UUID>.txt`)
/// inside the app container with strict `0700`/`0600` POSIX permissions (`SECURITY.md` §3.4, §6).
public final class SessionVault: Sendable {
    public let baseDirectory: URL
    private let lock = Mutex<Void>(())

    private static let sessionFilename = "session.json"
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    /// Creates a `SessionVault` targeting `Application Support/Kadmos/Session`.
    public init() {
        self.baseDirectory = Self.defaultBaseDirectory()
    }

    /// Creates a `SessionVault` rooted at a custom directory (intended for tests).
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Kadmos", isDirectory: true)
            .appendingPathComponent("Session", isDirectory: true)
            .standardizedFileURL
    }

    /// Saves a tab's unsaved draft text atomically to `draft-<UUID>.txt` with `0600` permissions.
    @discardableResult
    public func saveDraft(text: String, forTabID tabID: UUID) throws -> String {
        let filename = Self.draftFilename(for: tabID)
        return try lock.withLock { _ in
            try ensureSecureDirectoryLocked()
            let draftURL = baseDirectory.appendingPathComponent(filename, isDirectory: false)
            try rejectIfSymlinkLocked(at: draftURL)
            guard DocumentSecurity.validateWithinScope(candidate: draftURL, allowedRoot: baseDirectory) else {
                throw SessionVaultError.fileOutsideVaultScope
            }

            let data = Data(text.utf8)
            try data.write(to: draftURL, options: .atomic)
            try enforceFilePermissionsLocked(at: draftURL)
            KadmosLogger.infoPath(.session, message: "Saved session draft", path: draftURL.path)
            return filename
        }
    }

    /// Loads a previously saved draft by `draftFilename`, verifying scope and regular-file status.
    public func loadDraft(filename: String) throws -> String? {
        guard Self.isValidDraftFilename(filename) else {
            throw SessionVaultError.invalidDraftFilename
        }

        return try lock.withLock { _ in
            try rejectIfSymlinkLocked(at: baseDirectory)
            let draftURL = baseDirectory.appendingPathComponent(filename, isDirectory: false)
            try rejectIfSymlinkLocked(at: draftURL)
            guard DocumentSecurity.validateWithinScope(candidate: draftURL, allowedRoot: baseDirectory) else {
                throw SessionVaultError.fileOutsideVaultScope
            }

            guard let data = try readRegularFileIfExistsLocked(at: draftURL) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Persists `snapshot` to `session.json` with `0600` permissions and prunes stale `draft-*.txt` files.
    public func saveSnapshot(_ snapshot: SessionSnapshot) throws {
        try lock.withLock { _ in
            try ensureSecureDirectoryLocked()

            let sessionURL = baseDirectory.appendingPathComponent(Self.sessionFilename, isDirectory: false)
            try rejectIfSymlinkLocked(at: sessionURL)
            guard DocumentSecurity.validateWithinScope(candidate: sessionURL, allowedRoot: baseDirectory) else {
                throw SessionVaultError.fileOutsideVaultScope
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            try data.write(to: sessionURL, options: .atomic)
            try enforceFilePermissionsLocked(at: sessionURL)

            let referencedDrafts = Set(snapshot.tabs.compactMap(\.draftFilename))
            try pruneStaleDraftsLocked(keeping: referencedDrafts)

            KadmosLogger.infoPath(.session, message: "Saved session snapshot", path: sessionURL.path)
        }
    }

    /// Loads the persisted `session.json` snapshot, or returns `nil` if no session file exists.
    public func loadSnapshot() throws -> SessionSnapshot? {
        try lock.withLock { _ in
            try rejectIfSymlinkLocked(at: baseDirectory)
            let sessionURL = baseDirectory.appendingPathComponent(Self.sessionFilename, isDirectory: false)
            try rejectIfSymlinkLocked(at: sessionURL)
            guard DocumentSecurity.validateWithinScope(candidate: sessionURL, allowedRoot: baseDirectory) else {
                throw SessionVaultError.fileOutsideVaultScope
            }

            guard let data = try readRegularFileIfExistsLocked(at: sessionURL) else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SessionSnapshot.self, from: data)
        }
    }

    /// Deletes `session.json` and all draft files inside the vault (`SECURITY.md` §6).
    public func clearAll() throws {
        try lock.withLock { _ in
            try rejectIfSymlinkLocked(at: baseDirectory)
            let fm = FileManager.default
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
            } catch let error as NSError where Self.isFileNotFoundError(error) {
                return
            }
            for item in items {
                guard item.deletingLastPathComponent().standardizedFileURL == baseDirectory.standardizedFileURL else {
                    continue
                }
                try fm.removeItem(at: item)
            }
            KadmosLogger.infoPath(.session, message: "Cleared session vault", path: baseDirectory.path)
        }
    }

    /// Canonical filename helper for a tab's draft file.
    public static func draftFilename(for tabID: UUID) -> String {
        "draft-\(tabID.uuidString).txt"
    }

    /// Validates that a filename strictly conforms to `draft-<UUID>.txt` without path separators.
    public static func isValidDraftFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains(".."),
              filename.hasPrefix("draft-"),
              filename.hasSuffix(".txt") else {
            return false
        }
        let start = filename.index(filename.startIndex, offsetBy: "draft-".count)
        let end = filename.index(filename.endIndex, offsetBy: -".txt".count)
        let uuidString = String(filename[start..<end])
        return UUID(uuidString: uuidString) != nil
    }

    // MARK: - Locked Helpers

    private func ensureSecureDirectoryLocked() throws {
        try rejectIfSymlinkLocked(at: baseDirectory)
        let fm = FileManager.default
        try fm.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Self.directoryPermissions)]
        )
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: Self.directoryPermissions)],
            ofItemAtPath: baseDirectory.path
        )
    }

    private func enforceFilePermissionsLocked(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Self.filePermissions)],
            ofItemAtPath: url.path
        )
    }

    private func rejectIfSymlinkLocked(at url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw SessionVaultError.symlinkDetectedInVault
        }
    }

    private func readRegularFileIfExistsLocked(at url: URL) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT {
                return nil
            }
            if err == ELOOP {
                throw SessionVaultError.symlinkDetectedInVault
            }
            throw DocumentSecurityError.failedToOpenFile(message: String(cString: strerror(err)))
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw DocumentSecurityError.failedToStatFile(errno: err)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw DocumentSecurityError.notARegularFile
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    private static func isFileNotFoundError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return true
        }
        return false
    }

    private func pruneStaleDraftsLocked(keeping activeDrafts: Set<String>) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        for item in contents {
            let name = item.lastPathComponent
            guard name.hasPrefix("draft-"), name.hasSuffix(".txt") else {
                continue
            }
            if !activeDrafts.contains(name) {
                try? fm.removeItem(at: item)
            }
        }
    }
}

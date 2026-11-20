import Foundation
import KadmosCore
import Observation

/// A recently opened file backed by a macOS security-scoped bookmark (`SECURITY.md` §2.4).
public struct RecentFileEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let path: String
    public let bookmarkData: Data
    public let openedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        bookmarkData: Data,
        openedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
        self.openedAt = openedAt
    }
}

/// Errors raised while resolving security-scoped bookmarks.
public enum BookmarkStoreError: Error, LocalizedError, Sendable {
    case resolutionFailed

    public var errorDescription: String? {
        switch self {
        case .resolutionFailed:
            return "Dosya yer imi çözümlenemedi. Lütfen dosyayı Aç… iletişim kutusuyla yeniden seçin."
        }
    }
}

/// Manages up to 15 security-scoped recent file bookmarks in `UserDefaults` (`SECURITY.md` §2.4).
@Observable
@MainActor
public final class BookmarkStore {
    public static let shared = BookmarkStore()
    public static let maxRecentFiles = 15

    private static let defaultsKey = "kadmos.recentFiles"

    @ObservationIgnored private let defaults: UserDefaults

    public private(set) var recentFiles: [RecentFileEntry] = []

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadRecentFiles()
    }

    /// Creates (or preserves) a security-scoped bookmark for `url` and adds/promotes it in `recentFiles`.
    @discardableResult
    public func recordRecentFile(url: URL, existingBookmarkData: Data? = nil) -> Data? {
        let canonical = DocumentSecurity.resolveCanonicalURL(url).resolved
        let createdData = createSecurityScopedBookmark(for: canonical)
        let bookmarkData = createdData ?? existingBookmarkData

        guard let bookmarkData else {
            return nil
        }

        let entry = RecentFileEntry(
            displayName: canonical.lastPathComponent,
            path: canonical.path,
            bookmarkData: bookmarkData,
            openedAt: Date()
        )

        var updated = recentFiles.filter { $0.path != canonical.path }
        updated.insert(entry, at: 0)
        if updated.count > Self.maxRecentFiles {
            updated = Array(updated.prefix(Self.maxRecentFiles))
        }
        recentFiles = updated
        saveRecentFiles()
        return bookmarkData
    }

    /// Resolves `entry.bookmarkData` and refreshes it if stale, pairing any scoped access with `defer`.
    public func resolveAndAccess(entry: RecentFileEntry) -> URL? {
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: entry.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            KadmosLogger.warningPath(.security, message: "Failed to resolve recent file bookmark", path: entry.path)
            return nil
        }

        if isStale {
            let started = resolvedURL.startAccessingSecurityScopedResource()
            defer {
                if started {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
            }
            if let refreshed = createSecurityScopedBookmark(for: resolvedURL) {
                replaceBookmarkData(forPath: entry.path, newData: refreshed, newURL: resolvedURL)
            }
        }

        return resolvedURL
    }

    /// Resolves `bookmarkData`, activates security-scoped resource access, runs `perform`,
    /// and guarantees `stopAccessingSecurityScopedResource()` in `defer` (`SECURITY.md` §2.4).
    public func withScopedAccess<T>(
        to bookmarkData: Data,
        perform: (URL) throws -> T
    ) throws -> T {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            KadmosLogger.error(.security, message: "Unable to resolve security-scoped bookmark", error: error)
            throw BookmarkStoreError.resolutionFailed
        }

        let didStart = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        if isStale, let refreshed = createSecurityScopedBookmark(for: resolvedURL) {
            replaceBookmarkData(forPath: resolvedURL.path, newData: refreshed, newURL: resolvedURL)
        }

        return try perform(resolvedURL)
    }

    /// Async variant of `withScopedAccess(to:perform:)` for actor-isolated streaming reads (`SECURITY.md` §2.4).
    public func withScopedAccess<T>(
        to bookmarkData: Data,
        perform: (URL) async throws -> T
    ) async throws -> T {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            KadmosLogger.error(.security, message: "Unable to resolve async security-scoped bookmark", error: error)
            throw BookmarkStoreError.resolutionFailed
        }

        let didStart = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        if isStale, let refreshed = createSecurityScopedBookmark(for: resolvedURL) {
            replaceBookmarkData(forPath: resolvedURL.path, newData: refreshed, newURL: resolvedURL)
        }

        return try await perform(resolvedURL)
    }

    /// Removes all recent file entries and clears persisted bookmarks (`SECURITY.md` §6).
    public func clearRecentFiles() {
        recentFiles = []
        defaults.removeObject(forKey: Self.defaultsKey)
        KadmosLogger.info(.security, message: "Cleared recent files bookmark store")
    }

    /// Removes a specific broken/missing entry from recent files.
    public func removeRecentFile(id: UUID) {
        recentFiles.removeAll { $0.id == id }
        saveRecentFiles()
    }

    // MARK: - Private Helpers

    private func createSecurityScopedBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            KadmosLogger.warningPath(.security, message: "Failed to create security-scoped bookmark", path: url.path)
            return nil
        }
    }

    private func replaceBookmarkData(forPath path: String, newData: Data, newURL: URL) {
        guard let idx = recentFiles.firstIndex(where: { $0.path == path }) else { return }
        let old = recentFiles[idx]
        recentFiles[idx] = RecentFileEntry(
            id: old.id,
            displayName: newURL.lastPathComponent,
            path: newURL.path,
            bookmarkData: newData,
            openedAt: old.openedAt
        )
        saveRecentFiles()
    }

    private func loadRecentFiles() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            recentFiles = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([RecentFileEntry].self, from: data) {
            recentFiles = Array(decoded.prefix(Self.maxRecentFiles))
        } else {
            recentFiles = []
        }
    }

    private func saveRecentFiles() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(recentFiles) {
            defaults.set(encoded, forKey: Self.defaultsKey)
        }
    }
}

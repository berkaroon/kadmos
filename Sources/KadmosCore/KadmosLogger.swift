import Foundation
import OSLog

/// Centralized privacy-preserving logging facade for Kadmos.
///
/// All file system paths and error descriptions are logged with `.private`
/// redaction to uphold `SECURITY.md` §6, and document contents are never logged.
public enum KadmosLogger: Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case document
        case security
        case session
        case search
        case finder
    }

    public static let subsystem = "com.kadmos.macos"

    private static let documentLogger = Logger(subsystem: subsystem, category: Category.document.rawValue)
    private static let securityLogger = Logger(subsystem: subsystem, category: Category.security.rawValue)
    private static let sessionLogger = Logger(subsystem: subsystem, category: Category.session.rawValue)
    private static let searchLogger = Logger(subsystem: subsystem, category: Category.search.rawValue)
    private static let finderLogger = Logger(subsystem: subsystem, category: Category.finder.rawValue)

    /// Returns the `os.Logger` bound to the given subsystem category.
    public static func logger(for category: Category) -> Logger {
        switch category {
        case .document: return documentLogger
        case .security: return securityLogger
        case .session: return sessionLogger
        case .search: return searchLogger
        case .finder: return finderLogger
        }
    }

    /// Logs an informational event referencing a file path with `.private` redaction.
    public static func infoPath(_ category: Category, message: String, path: String) {
        let log = logger(for: category)
        log.info("\(message, privacy: .public) [path: \(path, privacy: .private)]")
    }

    /// Logs a warning event referencing a file path with `.private` redaction.
    public static func warningPath(_ category: Category, message: String, path: String) {
        let log = logger(for: category)
        log.warning("\(message, privacy: .public) [path: \(path, privacy: .private)]")
    }

    /// Logs an error event referencing a file path and optional error, redacting both with `.private`.
    public static func errorPath(
        _ category: Category,
        message: String,
        path: String,
        error: (any Error)? = nil
    ) {
        let log = logger(for: category)
        if let error {
            let description = String(describing: error)
            log.error(
                "\(message, privacy: .public) [path: \(path, privacy: .private)] [error: \(description, privacy: .private)]"
            )
        } else {
            log.error("\(message, privacy: .public) [path: \(path, privacy: .private)]")
        }
    }

    /// Logs a general informational message without file path or document data.
    public static func info(_ category: Category, message: String) {
        let log = logger(for: category)
        log.info("\(message, privacy: .public)")
    }

    /// Logs a general warning message without file path or document data.
    public static func warning(_ category: Category, message: String) {
        let log = logger(for: category)
        log.warning("\(message, privacy: .public)")
    }

    /// Logs a general error message with optional error details redacted as `.private`.
    public static func error(_ category: Category, message: String, error: (any Error)? = nil) {
        let log = logger(for: category)
        if let error {
            let description = String(describing: error)
            log.error("\(message, privacy: .public) [error: \(description, privacy: .private)]")
        } else {
            log.error("\(message, privacy: .public)")
        }
    }
}

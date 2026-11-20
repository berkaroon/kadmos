import Foundation

/// Validated custom URL scheme routes accepted by Kadmos (`SECURITY.md` §5).
public enum KadmosRoute: Equatable, Sendable {
    case newDocument(directory: URL?)
    case openRequest(file: URL?)
}

/// Errors produced when validating incoming `kadmos://` URLs.
public enum URLRouteError: Error, Equatable, Sendable {
    case invalidScheme
    case unknownHost
    case invalidPath
    case forbiddenControlCharacters
}

/// Strict validator for incoming `kadmos://` URL invocations (`SECURITY.md` §5).
///
/// Validation never creates, modifies, or opens files on disk; callers must still obtain
/// explicit user confirmation before acting on any parsed path.
public enum URLRouteValidator: Sendable {
    /// Validates `url` against the allowlisted `kadmos://` hosts and safe path constraints.
    public static func validate(_ url: URL) -> Result<KadmosRoute, URLRouteError> {
        let rawAbsolute = url.absoluteString
        if containsControlCharacters(rawAbsolute) {
            KadmosLogger.warning(.security, message: "Rejected URL route containing raw control characters")
            return .failure(.forbiddenControlCharacters)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.invalidPath)
        }

        guard let scheme = components.scheme?.lowercased(), scheme == "kadmos" else {
            return .failure(.invalidScheme)
        }

        guard components.user == nil, components.password == nil, components.port == nil else {
            return .failure(.unknownHost)
        }

        let path = components.path
        guard path.isEmpty || path == "/" else {
            return .failure(.unknownHost)
        }

        guard let host = components.host?.lowercased() else {
            return .failure(.unknownHost)
        }

        // Reject control characters across all decoded query items before route-specific handling.
        for item in components.queryItems ?? [] {
            if containsControlCharacters(item.name) || (item.value.map(containsControlCharacters) ?? false) {
                KadmosLogger.warning(.security, message: "Rejected URL route containing control characters in query")
                return .failure(.forbiddenControlCharacters)
            }
        }

        switch host {
        case "new-document":
            switch validatedPathParameter(named: "dir", in: components.queryItems) {
            case .success(let directory):
                return .success(.newDocument(directory: directory))
            case .failure(let error):
                return .failure(error)
            }

        case "open-request":
            switch validatedPathParameter(named: "file", in: components.queryItems) {
            case .success(let file):
                return .success(.openRequest(file: file))
            case .failure(let error):
                return .failure(error)
            }

        default:
            return .failure(.unknownHost)
        }
    }

    private static func validatedPathParameter(
        named key: String,
        in queryItems: [URLQueryItem]?
    ) -> Result<URL?, URLRouteError> {
        let matching = (queryItems ?? []).filter { $0.name == key }
        guard matching.count <= 1 else {
            return .failure(.invalidPath)
        }
        guard let item = matching.first else {
            return .success(nil)
        }
        guard let rawPath = item.value, !rawPath.isEmpty else {
            return .failure(.invalidPath)
        }

        if containsControlCharacters(rawPath) {
            return .failure(.forbiddenControlCharacters)
        }

        // Require an absolute POSIX path and forbid traversal or UNC/backslash confusion.
        guard rawPath.hasPrefix("/"),
              !rawPath.hasPrefix("//"),
              !rawPath.contains("\\") else {
            return .failure(.invalidPath)
        }

        let rawSegments = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        if rawSegments.contains("..") || rawSegments.contains(".") {
            return .failure(.invalidPath)
        }

        let fileURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        if fileURL.pathComponents.contains("..") {
            return .failure(.invalidPath)
        }

        let (canonicalURL, _) = DocumentSecurity.resolveCanonicalURL(fileURL)
        if canonicalURL.pathComponents.contains("..") {
            return .failure(.invalidPath)
        }

        return .success(canonicalURL)
    }

    private static func containsControlCharacters(_ string: String) -> Bool {
        for scalar in string.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || (scalar.value >= 0x80 && scalar.value <= 0x9F) {
                return true
            }
        }
        return false
    }
}

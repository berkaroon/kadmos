import AppKit
import Foundation
import Observation

/// Application appearance preference mapped directly to `NSApp.appearance`.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "Sistem"
        case .light: return "Açık"
        case .dark: return "Koyu"
        }
    }

    @MainActor
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Behavior when Kadmos launches without explicit incoming document URLs.
public enum StartupBehavior: String, CaseIterable, Identifiable, Sendable {
    case continuePreviousSession
    case startNewSession

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .continuePreviousSession: return "Önceki oturumdan devam et"
        case .startNewSession: return "Yeni pencere aç"
        }
    }
}

/// Target container when opening external files from Finder or the Open panel.
public enum OpenFilesTarget: String, CaseIterable, Identifiable, Sendable {
    case newTab
    case newWindow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .newTab: return "Yeni sekmede aç"
        case .newWindow: return "Yeni pencerede aç"
        }
    }
}

/// User preferences persisted in `UserDefaults.standard`.
///
/// Stores preferences only — never secrets, credentials, or document content (`SECURITY.md` §6).
@Observable
@MainActor
public final class KadmosSettings {
    public static let shared = KadmosSettings()

    public static let defaultIgnoredSpellCheckExtensions: [String] = [
        "json", "xml", "swift", "py", "js", "ts", "tsx", "jsx",
        "html", "css", "yaml", "yml", "toml", "ini", "conf", "cfg",
        "log", "sh", "zsh", "bash", "c", "h", "cpp", "hpp",
        "rs", "go", "sql", "java", "rb", "env"
    ]

    public static let minFontSize: Double = 8.0
    public static let maxFontSize: Double = 72.0

    private enum Keys {
        static let appearance = "kadmos.settings.appearance"
        static let fontFamily = "kadmos.settings.fontFamily"
        static let fontStyle = "kadmos.settings.fontStyle"
        static let fontSize = "kadmos.settings.fontSize"
        static let wordWrap = "kadmos.settings.wordWrap"
        static let showStatusBar = "kadmos.settings.showStatusBar"
        static let startupBehavior = "kadmos.settings.startupBehavior"
        static let openFilesTarget = "kadmos.settings.openFilesTarget"
        static let spellCheckEnabled = "kadmos.settings.spellCheckEnabled"
        static let autocorrectEnabled = "kadmos.settings.autocorrectEnabled"
        static let spellCheckIgnoredExtensions = "kadmos.settings.spellCheckIgnoredExtensions"
        static let highlightTrojanChars = "kadmos.settings.highlightTrojanChars"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    public var fontFamily: String {
        didSet {
            defaults.set(fontFamily, forKey: Keys.fontFamily)
        }
    }

    public var fontStyle: String {
        didSet {
            defaults.set(fontStyle, forKey: Keys.fontStyle)
        }
    }

    public var fontSize: Double {
        didSet {
            let clamped = Self.clampFontSize(fontSize)
            if fontSize != clamped {
                fontSize = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.fontSize)
        }
    }

    public var wordWrap: Bool {
        didSet {
            defaults.set(wordWrap, forKey: Keys.wordWrap)
        }
    }

    public var showStatusBar: Bool {
        didSet {
            defaults.set(showStatusBar, forKey: Keys.showStatusBar)
        }
    }

    public var startupBehavior: StartupBehavior {
        didSet {
            defaults.set(startupBehavior.rawValue, forKey: Keys.startupBehavior)
        }
    }

    public var openFilesTarget: OpenFilesTarget {
        didSet {
            defaults.set(openFilesTarget.rawValue, forKey: Keys.openFilesTarget)
        }
    }

    public var spellCheckEnabled: Bool {
        didSet {
            defaults.set(spellCheckEnabled, forKey: Keys.spellCheckEnabled)
        }
    }

    public var autocorrectEnabled: Bool {
        didSet {
            defaults.set(autocorrectEnabled, forKey: Keys.autocorrectEnabled)
        }
    }

    public var spellCheckIgnoredExtensions: [String] {
        didSet {
            let normalized = Self.normalizeExtensions(spellCheckIgnoredExtensions)
            if spellCheckIgnoredExtensions != normalized {
                spellCheckIgnoredExtensions = normalized
                return
            }
            defaults.set(normalized, forKey: Keys.spellCheckIgnoredExtensions)
        }
    }

    public var highlightTrojanChars: Bool {
        didSet {
            defaults.set(highlightTrojanChars, forKey: Keys.highlightTrojanChars)
        }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawAppearance = defaults.string(forKey: Keys.appearance),
           let parsed = AppAppearance(rawValue: rawAppearance) {
            self.appearance = parsed
        } else {
            self.appearance = .system
        }

        if let storedFamily = defaults.string(forKey: Keys.fontFamily), !storedFamily.isEmpty {
            self.fontFamily = storedFamily
        } else {
            self.fontFamily = "SF Mono"
        }

        if let storedStyle = defaults.string(forKey: Keys.fontStyle), !storedStyle.isEmpty {
            self.fontStyle = storedStyle
        } else {
            self.fontStyle = "Regular"
        }

        if defaults.object(forKey: Keys.fontSize) != nil {
            self.fontSize = Self.clampFontSize(defaults.double(forKey: Keys.fontSize))
        } else {
            self.fontSize = 14.0
        }

        self.wordWrap = defaults.object(forKey: Keys.wordWrap) as? Bool ?? true
        self.showStatusBar = defaults.object(forKey: Keys.showStatusBar) as? Bool ?? true

        if let rawStartup = defaults.string(forKey: Keys.startupBehavior),
           let parsed = StartupBehavior(rawValue: rawStartup) {
            self.startupBehavior = parsed
        } else {
            self.startupBehavior = .continuePreviousSession
        }

        if let rawTarget = defaults.string(forKey: Keys.openFilesTarget),
           let parsed = OpenFilesTarget(rawValue: rawTarget) {
            self.openFilesTarget = parsed
        } else {
            self.openFilesTarget = .newTab
        }

        self.spellCheckEnabled = defaults.object(forKey: Keys.spellCheckEnabled) as? Bool ?? true
        self.autocorrectEnabled = defaults.object(forKey: Keys.autocorrectEnabled) as? Bool ?? false

        if let storedExtensions = defaults.stringArray(forKey: Keys.spellCheckIgnoredExtensions) {
            self.spellCheckIgnoredExtensions = Self.normalizeExtensions(storedExtensions)
        } else {
            self.spellCheckIgnoredExtensions = Self.defaultIgnoredSpellCheckExtensions
        }

        self.highlightTrojanChars = defaults.object(forKey: Keys.highlightTrojanChars) as? Bool ?? true

        applyAppearance()
    }

    /// Applies the active appearance selection to `NSApp`.
    public func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// Available font families offered in Settings, keeping `"SF Mono"` and `"Menlo"` first.
    public var availableFontFamilies: [String] {
        var families = NSFontManager.shared.availableFontFamilies.sorted()
        if !families.contains("Menlo") {
            families.insert("Menlo", at: 0)
        }
        families.removeAll { $0 == "SF Mono" }
        families.insert("SF Mono", at: 0)
        return families
    }

    /// Available style names for `family`.
    public func availableStyles(forFamily family: String) -> [String] {
        if family == "SF Mono" {
            return ["Regular", "Medium", "Semibold", "Bold", "Light", "Italic", "Bold Italic"]
        }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        var styles: [String] = []
        for member in members {
            if member.count >= 2, let styleName = member[1] as? String, !styles.contains(styleName) {
                styles.append(styleName)
            }
        }
        return styles.isEmpty ? ["Regular"] : styles
    }

    /// Resolves the configured `NSFont` scaled by `zoomPercent`, with clean fallback to `Menlo` / monospaced system font.
    public func resolvedNSFont(zoomPercent: Int = 100) -> NSFont {
        let clampedBase = Self.clampFontSize(fontSize)
        let clampedZoom = max(10, min(zoomPercent, 500))
        let scaledSize = max(4.0, CGFloat(clampedBase) * CGFloat(clampedZoom) / 100.0)

        if fontFamily == "SF Mono" {
            return resolveSFMonoFont(style: fontStyle, size: scaledSize)
        }

        if let font = resolveNamedFont(family: fontFamily, style: fontStyle, size: scaledSize) {
            return font
        }

        if let menlo = resolveNamedFont(family: "Menlo", style: fontStyle, size: scaledSize)
            ?? NSFont(name: "Menlo-Regular", size: scaledSize) {
            return menlo
        }

        return NSFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)
    }

    /// Resets ignored spell-check extensions to the built-in developer defaults.
    public func resetIgnoredSpellCheckExtensions() {
        spellCheckIgnoredExtensions = Self.defaultIgnoredSpellCheckExtensions
    }

    // MARK: - Helpers

    private func resolveSFMonoFont(style: String, size: CGFloat) -> NSFont {
        let lower = style.lowercased()
        let weight: NSFont.Weight
        if lower.contains("bold") && !lower.contains("semi") {
            weight = .bold
        } else if lower.contains("semibold") {
            weight = .semibold
        } else if lower.contains("medium") {
            weight = .medium
        } else if lower.contains("light") {
            weight = .light
        } else if lower.contains("heavy") {
            weight = .heavy
        } else if lower.contains("thin") {
            weight = .thin
        } else {
            weight = .regular
        }

        let base = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        if lower.contains("italic") || lower.contains("oblique") {
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            return italic
        }
        return base
    }

    private func resolveNamedFont(family: String, style: String, size: CGFloat) -> NSFont? {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let targetStyle = style.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let exact = members.first(where: {
            $0.count >= 2 && (($0[1] as? String)?.lowercased() == targetStyle)
        }), let postScriptName = exact.first as? String,
           let font = NSFont(name: postScriptName, size: size) {
            return font
        }

        if let regular = members.first(where: {
            $0.count >= 2 && (($0[1] as? String)?.lowercased() == "regular")
        }), let postScriptName = regular.first as? String,
           let font = NSFont(name: postScriptName, size: size) {
            return font
        }

        if let first = members.first,
           let postScriptName = first.first as? String,
           let font = NSFont(name: postScriptName, size: size) {
            return font
        }

        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        return NSFont(descriptor: descriptor, size: size)
    }

    private static func clampFontSize(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 14.0, minFontSize), maxFontSize)
    }

    private static func normalizeExtensions(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }
}

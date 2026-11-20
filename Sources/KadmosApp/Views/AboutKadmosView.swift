import AppKit
import SwiftUI

/// Native Apple-style About Kadmos window displaying the bundle icon, version, and Profile A summary.
public struct AboutKadmosView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: loadAppIcon())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)

            VStack(spacing: 4) {
                Text("Kadmos")
                    .font(.system(size: 22, weight: .bold))

                Text("Sürüm \(appVersionString)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("macOS için Yerel Düz Metin Editörü")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .padding(.top, 2)
            }

            Text("App Sandbox • Hardened Runtime • Çevrimdışı")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())

            Text(copyrightString)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 360)
    }

    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (short?.isEmpty == false) ? short! : "1.0.0"
    }

    private var copyrightString: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        return (raw?.isEmpty == false) ? raw! : "© 2026 Kadmos"
    }

    private func loadAppIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "kadmos-icon-1024", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp?.applicationIconImage ?? NSImage()
    }
}

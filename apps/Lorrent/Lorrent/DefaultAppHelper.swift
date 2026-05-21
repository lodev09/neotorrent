import AppKit
import UniformTypeIdentifiers

/// Helpers for checking and setting Lorrent as the macOS default handler for
/// `magnet:` URLs and `.torrent` files.
@MainActor
enum DefaultAppHelper {
    static var lorrentBundleURL: URL { Bundle.main.bundleURL }
    static var lorrentBundleID: String? { Bundle.main.bundleIdentifier }

    static var magnetProbeURL: URL { URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000")! }

    static var torrentContentType: UTType {
        // We declared org.bittorrent.torrent in Info.plist (UTImportedTypeDeclarations).
        UTType(importedAs: "org.bittorrent.torrent")
    }

    static var isDefaultForMagnet: Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: magnetProbeURL) else {
            return false
        }
        return appURL.standardizedFileURL == lorrentBundleURL.standardizedFileURL
    }

    static var isDefaultForTorrent: Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: torrentContentType) else {
            return false
        }
        return appURL.standardizedFileURL == lorrentBundleURL.standardizedFileURL
    }

    static func currentMagnetHandlerName() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: magnetProbeURL) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func currentTorrentHandlerName() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: torrentContentType) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func setAsDefaultForMagnet() async -> Error? {
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: lorrentBundleURL,
                toOpenURLsWithScheme: "magnet"
            )
            return nil
        } catch {
            return error
        }
    }

    static func setAsDefaultForTorrent() async -> Error? {
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: lorrentBundleURL,
                toOpen: torrentContentType
            )
            return nil
        } catch {
            return error
        }
    }
}

extension NSWorkspace {
    /// Convenience overload for resolving the default handler for a UTType.
    func urlForApplication(toOpen contentType: UTType) -> URL? {
        urlsForApplications(toOpen: contentType).first
    }
}

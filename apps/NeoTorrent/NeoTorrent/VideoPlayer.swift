import AppKit

/// An app that media is handed to. Players with a known CLI run as a child
/// process so playback can be stopped; any other app is opened via Launch
/// Services.
struct VideoPlayer {
    let bundleID: String
    let appURL: URL

    var name: String { appURL.deletingPathExtension().lastPathComponent }

    /// CLI invocation that plays `media`, if this player has one.
    func command(for media: URL) -> (executable: URL, arguments: [String])? {
        let target = media.isFileURL ? media.path : media.absoluteString
        let cli: (name: String, arguments: [String])
        switch bundleID {
        case "org.videolan.vlc": cli = ("VLC", [target, "--play-and-exit"])
        case "com.colliderli.iina": cli = ("iina-cli", ["--keep-running", "--no-stdin", target])
        case "io.mpv": cli = ("mpv", [target])
        default: return nil
        }
        let executable = appURL.appendingPathComponent("Contents/MacOS/\(cli.name)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return (executable, cli.arguments)
    }

    /// Preferred order for "Automatic".
    private static let known = ["org.videolan.vlc", "com.colliderli.iina", "io.mpv"]

    static func installed(_ bundleID: String) -> VideoPlayer? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return VideoPlayer(bundleID: bundleID, appURL: url)
    }

    static var installedKnown: [VideoPlayer] { known.compactMap(installed) }

    /// Empty `bundleID` (or one no longer installed) means the first installed
    /// known player; nil means none, so fall back to the system default.
    static func resolve(_ bundleID: String) -> VideoPlayer? {
        if !bundleID.isEmpty, let player = installed(bundleID) { return player }
        return installedKnown.first
    }
}

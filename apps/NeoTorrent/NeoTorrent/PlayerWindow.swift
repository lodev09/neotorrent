@preconcurrency import SwiftUI
@preconcurrency import AVKit

struct PlayerWindow: View {
    let url: URL
    let title: String

    var body: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .navigationTitle(title)
            .frame(minWidth: 640, minHeight: 360)
    }
}

private let playableExtensions: Set<String> = [
    "mp4", "m4v", "mov", "mkv", "webm", "avi",
    "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
]

extension TorrentFile {
    var isPlayable: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return playableExtensions.contains(ext)
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}

/// Open a streaming video window for a file in a torrent.
@MainActor
func openPlayerWindow(session: NeoTorrentSession, torrentID: UInt64, file: TorrentFile) {
    let urlString = session.streamUrl(id: torrentID, fileIndex: file.index)
    guard let url = URL(string: urlString) else { return }

    let player = AVPlayer(url: url)
    let controller = AVPlayerView()
    controller.player = player
    controller.controlsStyle = .default
    controller.showsFullScreenToggleButton = true

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.title = file.displayName
    window.contentView = controller
    window.center()
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Hold a strong reference until the window closes.
    let observerBox = ObserverBox()
    observerBox.token = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
    ) { [observerBox] _ in
        player.pause()
        if let token = observerBox.token {
            NotificationCenter.default.removeObserver(token)
            observerBox.token = nil
        }
    }
}

private final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
}

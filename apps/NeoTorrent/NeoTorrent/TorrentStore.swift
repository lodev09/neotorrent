import SwiftUI
import AppKit
import UserNotifications

extension TorrentSnapshot {
    var isPaused: Bool { state.lowercased() == "paused" }
}

/// App-level torrent state. Owns the poll loop so progress, notifications,
/// sounds, and the menu bar keep working while the main window is closed.
@MainActor
@Observable
final class TorrentStore {
    private(set) var torrents: [TorrentSnapshot] = []
    private(set) var playableURLs: [UInt64: URL] = [:]
    private(set) var playingTorrentID: UInt64?

    private var sessionHolder: SessionHolder?
    private var prefs: Preferences?
    private var posters: PosterStore?
    private var playingProcess: Process?
    private var pollTask: Task<Void, Never>?
    private var removingIDs: Set<UInt64> = []
    private var notifiedFinishedIDs: Set<UInt64> = []
    private var didInitialLoad = false
    private var lastBadge = ""

    var downloading: [TorrentSnapshot] { torrents.filter { !$0.isFinished && !$0.isPaused } }
    var seedingCount: Int { torrents.filter { $0.isFinished && !$0.isPaused }.count }
    var pausedCount: Int { torrents.filter(\.isPaused).count }
    var totalDownloadBps: UInt64 { torrents.reduce(0) { $0 + $1.downloadBps } }
    var totalUploadBps: UInt64 { torrents.reduce(0) { $0 + $1.uploadBps } }

    /// Aggregate progress across actively downloading torrents; nil when idle.
    var aggregateProgress: Double? {
        let active = downloading.filter { $0.totalBytes > 0 }
        let total = active.reduce(UInt64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return nil }
        let done = active.reduce(UInt64(0)) { $0 + $1.downloadedBytes }
        return min(1, Double(done) / Double(total))
    }

    func start(sessionHolder: SessionHolder, prefs: Preferences, posters: PosterStore) {
        self.sessionHolder = sessionHolder
        self.prefs = prefs
        self.posters = posters
        guard pollTask == nil else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() {
        guard let sessionHolder, let session = sessionHolder.session else { return }
        let updated = session.list()
        let previousIDs = Set(torrents.map(\.id))
        let newlyAdded = updated.filter { !previousIDs.contains($0.id) }

        for t in updated where t.isFinished && !notifiedFinishedIDs.contains(t.id) {
            if let prev = torrents.first(where: { $0.id == t.id }), !prev.isFinished {
                postCompletionNotification(for: t)
                playSound("Funk")
            }
            notifiedFinishedIDs.insert(t.id)
        }

        let next = updated
            .filter { !removingIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        // Only invalidate observers when something actually changed.
        if next != torrents { torrents = next }
        sessionHolder.reconcilePending(against: Set(updated.map(\.id)))

        if didInitialLoad && !newlyAdded.isEmpty { playSound("Pop") }
        didInitialLoad = true
        updateDockBadge()
        refreshPlayableURLs()
    }

    // MARK: - Streaming

    func togglePlayback(id: UInt64) {
        if playingTorrentID == id, let proc = playingProcess, proc.isRunning {
            proc.terminate()
            playingProcess = nil
            playingTorrentID = nil
            return
        }
        if let proc = playingProcess, proc.isRunning { proc.terminate() }
        playingProcess = nil
        playingTorrentID = nil
        guard let url = playableURLs[id] else { return }
        playInVLC(url: url, torrentID: id)
    }

    private func playInVLC(url: URL, torrentID: UInt64) {
        guard let vlcAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") else {
            NSWorkspace.shared.open(url)
            return
        }
        let binary = vlcAppURL.appendingPathComponent("Contents/MacOS/VLC")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            NSWorkspace.shared.open(url)
            return
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [url.absoluteString, "--play-and-exit"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [proc] _ in
            Task { @MainActor in
                if self.playingProcess === proc {
                    self.playingProcess = nil
                    self.playingTorrentID = nil
                }
            }
        }
        do {
            try proc.run()
            playingProcess = proc
            playingTorrentID = torrentID
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshPlayableURLs() {
        guard let session = sessionHolder?.session else { return }
        var next: [UInt64: URL] = [:]
        for t in torrents {
            guard let files = try? session.files(id: t.id),
                  let media = largestPlayableMedia(in: files) else { continue }
            let base = session.streamUrl(id: t.id, fileIndex: media.index)
            let filename = (media.path as NSString).lastPathComponent
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            if let url = URL(string: "\(base)/\(encoded)") {
                next[t.id] = url
            }
            if media.downloaded > 0, let local = localFileURL(torrentID: t.id, file: media, session: session) {
                posters?.ensure(infoHash: t.infoHash, fileURL: local)
            }
        }
        if next != playableURLs { playableURLs = next }
    }

    private func localFileURL(torrentID: UInt64, file: TorrentFile, session: NeoTorrentSession) -> URL? {
        guard let folder = try? session.outputFolder(id: torrentID) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) else { return nil }
        let url = URL(fileURLWithPath: folder)
        return isDir.boolValue ? url.appendingPathComponent(file.path) : url
    }

    private func largestPlayableMedia(in files: [TorrentFile]) -> TorrentFile? {
        files
            .filter { $0.selected && isMediaExtension(($0.path as NSString).pathExtension) }
            .max(by: { $0.length < $1.length })
    }

    private func isMediaExtension(_ ext: String) -> Bool {
        let media: Set<String> = [
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
            "mpg", "mpeg", "ts", "3gp",
            "mp3", "m4a", "aac", "ogg", "flac", "wav", "opus"
        ]
        return media.contains(ext.lowercased())
    }

    func pause(id: UInt64) {
        playSound("Morse")
        Task {
            try? await sessionHolder?.session?.pause(id: id)
            refresh()
        }
    }

    func resume(id: UInt64) {
        playSound("Morse")
        Task {
            try? await sessionHolder?.session?.resume(id: id)
            refresh()
        }
    }

    func remove(id: UInt64, deleteFiles: Bool) {
        playSound("Bottle")
        removingIDs.insert(id)
        torrents.removeAll { $0.id == id }
        notifiedFinishedIDs.remove(id)
        Task {
            try? await sessionHolder?.session?.remove(id: id, deleteFiles: deleteFiles)
            removingIDs.remove(id)
        }
    }

    func revealInFinder(id: UInt64) {
        guard let session = sessionHolder?.session,
              let path = try? session.outputFolder(id: id) else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func playSound(_ name: String) {
        guard prefs?.playSounds == true else { return }
        NSSound(named: name)?.play()
    }

    private func updateDockBadge() {
        let badge = downloading.isEmpty ? "" : "\(downloading.count)"
        guard badge != lastBadge else { return }
        lastBadge = badge
        NSApp.dockTile.badgeLabel = badge.isEmpty ? nil : badge
    }

    private func postCompletionNotification(for t: TorrentSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = t.name ?? "Torrent finished"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "neotorrent-finished-\(t.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

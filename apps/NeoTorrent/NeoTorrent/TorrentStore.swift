import SwiftUI
import AppKit
import UserNotifications

extension TorrentSnapshot {
    var isPaused: Bool { state == .paused }
    /// Verifying existing data (after launch, resume, or re-add).
    var isChecking: Bool { state == .initializing }
    var isErrored: Bool { state == .error }
}

/// App-level torrent state. Owns the poll loop so progress, notifications,
/// and sounds keep working while the main window is closed.
@MainActor
@Observable
final class TorrentStore {
    private(set) var torrents: [TorrentSnapshot] = []
    private(set) var files: [UInt64: [TorrentFile]] = [:]
    private(set) var playableURLs: [UInt64: URL] = [:]
    private(set) var playingTorrentID: UInt64?

    @ObservationIgnored private var sessionHolder: SessionHolder?
    @ObservationIgnored private var prefs: Preferences?
    @ObservationIgnored private var posters: PosterStore?
    @ObservationIgnored private var playingProcess: Process?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var removingIDs: Set<UInt64> = []
    @ObservationIgnored private var notifiedFinishedIDs: Set<UInt64> = []
    @ObservationIgnored private var ratioPausedIDs: Set<UInt64> = []
    @ObservationIgnored private var didInitialLoad = false
    @ObservationIgnored private var lastBadge = ""
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?

    static let vlcBinary: URL? = {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") else {
            return nil
        }
        let binary = app.appendingPathComponent("Contents/MacOS/VLC")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }()

    private var downloading: [TorrentSnapshot] { torrents.filter { !$0.isFinished && $0.state == .live } }

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
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Poll the engine off the main thread and publish the result.
    func refresh() async {
        guard let session = sessionHolder?.session else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let needsPoster = Set(torrents.map(\.infoHash).filter { posters?.wantsPoster(for: $0) ?? false })
        let poll = await Task.detached(priority: .utility) {
            Self.poll(session, needsPoster: needsPoster)
        }.value
        // A newer refresh started while this one was in flight.
        guard generation == refreshGeneration else { return }
        apply(poll)
    }

    private struct Poll: Sendable {
        var torrents: [TorrentSnapshot]
        var files: [UInt64: [TorrentFile]]
        var playable: [UInt64: URL]
        var posterSources: [String: URL]
    }

    nonisolated private static func poll(_ session: NeoTorrentSession, needsPoster: Set<String>) -> Poll {
        let torrents = session.list().sorted { $0.id < $1.id }
        var files: [UInt64: [TorrentFile]] = [:]
        var playable: [UInt64: URL] = [:]
        var posterSources: [String: URL] = [:]
        for t in torrents {
            let torrentFiles = (try? session.files(id: t.id)) ?? []
            files[t.id] = torrentFiles
            guard let media = largestPlayableMedia(in: torrentFiles) else { continue }
            let base = session.streamUrl(id: t.id, fileIndex: media.index)
            let filename = (media.path as NSString).lastPathComponent
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            if let url = URL(string: "\(base)/\(encoded)") {
                playable[t.id] = url
            }
            let ext = (media.path as NSString).pathExtension.lowercased()
            if needsPoster.contains(t.infoHash), media.downloaded > 0, PosterStore.posterExtensions.contains(ext),
               let folder = try? session.outputFolder(id: t.id) {
                let local = URL(fileURLWithPath: folder).appendingPathComponent(media.path)
                if FileManager.default.fileExists(atPath: local.path) {
                    posterSources[t.infoHash] = local
                }
            }
        }
        return Poll(torrents: torrents, files: files, playable: playable, posterSources: posterSources)
    }

    private func apply(_ poll: Poll) {
        let previous = Dictionary(uniqueKeysWithValues: torrents.map { ($0.id, $0) })
        let newlyAdded = poll.torrents.filter { previous[$0.id] == nil && !removingIDs.contains($0.id) }

        for t in poll.torrents where t.isFinished && !notifiedFinishedIDs.contains(t.id) {
            // Torrents restored at launch report unfinished until their data
            // is checked; finishing that check isn't a completed download.
            if let prev = previous[t.id], !prev.isFinished, !prev.isChecking {
                postCompletionNotification(for: t)
                playSound("Funk")
            }
            notifiedFinishedIDs.insert(t.id)
        }

        let next = poll.torrents.filter { !removingIDs.contains($0.id) }
        // Only invalidate observers when something actually changed.
        if next != torrents { torrents = next }
        if poll.files != files { files = poll.files }
        if poll.playable != playableURLs { playableURLs = poll.playable }
        sessionHolder?.reconcilePending(against: Set(poll.torrents.map(\.id)))
        for (infoHash, url) in poll.posterSources {
            posters?.ensure(infoHash: infoHash, fileURL: url)
        }

        if didInitialLoad && !newlyAdded.isEmpty { playSound("Pop") }
        didInitialLoad = true
        enforceSeedRatio()
        updateDockBadge()
        updateSleepPrevention()
    }

    // MARK: - Actions

    func pause(id: UInt64) {
        playSound("Morse")
        perform("Couldn't pause") { try await $0.pause(id: id) }
    }

    func resume(id: UInt64) {
        playSound("Morse")
        perform("Couldn't resume") { try await $0.resume(id: id) }
    }

    func remove(id: UInt64, deleteFiles: Bool) {
        guard let session = sessionHolder?.session else { return }
        playSound("Bottle")
        if playingTorrentID == id { stopPlayback() }
        let infoHash = torrents.first { $0.id == id }?.infoHash
        removingIDs.insert(id)
        torrents.removeAll { $0.id == id }
        notifiedFinishedIDs.remove(id)
        ratioPausedIDs.remove(id)
        Task {
            do {
                try await session.remove(id: id, deleteFiles: deleteFiles)
                if let infoHash { posters?.remove(infoHash: infoHash) }
            } catch {
                sessionHolder?.errorMessage = "Couldn't remove: \(errorDetail(error))"
            }
            removingIDs.remove(id)
        }
    }

    func setFile(_ file: TorrentFile, selected: Bool, torrentID: UInt64) {
        let indices = (files[torrentID] ?? [])
            .filter { $0.index == file.index ? selected : $0.selected }
            .map(\.index)
        // librqbit can't download an empty selection.
        guard !indices.isEmpty else {
            NSSound.beep()
            return
        }
        perform("Couldn't change file selection") { try await $0.setOnlyFiles(id: torrentID, indices: indices) }
    }

    func revealInFinder(id: UInt64) {
        guard let session = sessionHolder?.session,
              let folder = try? session.outputFolder(id: id) else { return }
        let torrentFiles = files[id] ?? []
        let path = torrentFiles.count == 1
            ? (folder as NSString).appendingPathComponent(torrentFiles[0].path)
            : folder
        if !NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        }
    }

    private func perform(
        _ failure: String,
        _ action: @escaping @MainActor (NeoTorrentSession) async throws -> Void
    ) {
        guard let session = sessionHolder?.session else { return }
        Task {
            do {
                try await action(session)
            } catch {
                sessionHolder?.errorMessage = "\(failure): \(errorDetail(error))"
            }
            await refresh()
        }
    }

    // MARK: - Streaming

    func togglePlayback(id: UInt64) {
        let wasPlaying = playingTorrentID == id
        stopPlayback()
        guard !wasPlaying, let url = playableURLs[id] else { return }
        guard let binary = Self.vlcBinary else {
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
            playingTorrentID = id
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    func stopPlayback() {
        if let proc = playingProcess, proc.isRunning { proc.terminate() }
        playingProcess = nil
        playingTorrentID = nil
    }

    nonisolated private static func largestPlayableMedia(in files: [TorrentFile]) -> TorrentFile? {
        files
            .filter { $0.selected && isMediaExtension(($0.path as NSString).pathExtension) }
            .max(by: { $0.length < $1.length })
    }

    nonisolated private static func isMediaExtension(_ ext: String) -> Bool {
        let media: Set<String> = [
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
            "mpg", "mpeg", "ts", "3gp",
            "mp3", "m4a", "aac", "ogg", "flac", "wav", "opus"
        ]
        return media.contains(ext.lowercased())
    }

    // MARK: - Housekeeping

    func playSound(_ name: String) {
        guard prefs?.playSounds == true else { return }
        NSSound(named: name)?.play()
    }

    /// Pause completed torrents once they've uploaded `seedRatioLimit` × their
    /// size. Each torrent is paused at most once per launch, so resuming it
    /// by hand keeps it seeding.
    private func enforceSeedRatio() {
        guard let limit = prefs?.seedRatioLimit, limit > 0, let session = sessionHolder?.session else { return }
        for t in torrents where t.isFinished && t.state == .live && t.totalBytes > 0
            && !ratioPausedIDs.contains(t.id)
            && Double(t.uploadedBytes) / Double(t.totalBytes) >= limit {
            ratioPausedIDs.insert(t.id)
            Task {
                do { try await session.pause(id: t.id) }
                catch { sessionHolder?.errorMessage = "Couldn't stop seeding: \(errorDetail(error))" }
            }
        }
    }

    private func updateDockBadge() {
        let badge = downloading.isEmpty ? "" : "\(downloading.count)"
        guard badge != lastBadge else { return }
        lastBadge = badge
        NSApp.dockTile.badgeLabel = badge.isEmpty ? nil : badge
    }

    private func updateSleepPrevention() {
        let prevent = prefs?.preventSleep == true && !downloading.isEmpty
        if prevent, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Downloading torrents"
            )
        } else if !prevent, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func postCompletionNotification(for t: TorrentSnapshot) {
        // Silent: the Funk chime (respecting "Play sound effects") is the sound.
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = t.name ?? "Torrent finished"
        let req = UNNotificationRequest(
            identifier: "neotorrent-finished-\(t.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

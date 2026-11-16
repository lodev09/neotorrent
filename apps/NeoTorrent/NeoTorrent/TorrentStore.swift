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
    @ObservationIgnored private var lastDockPercent: Int?
    @ObservationIgnored private var dockProgress: DockProgressView?
    @ObservationIgnored private var fileProgress: [UInt64: Progress] = [:]
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?

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
            // Completed files play from disk so any player can open them.
            let complete = media.downloaded == media.length
            let ext = (media.path as NSString).pathExtension.lowercased()
            let wantsPoster = needsPoster.contains(t.infoHash) && media.downloaded > 0
                && PosterStore.posterExtensions.contains(ext)
            if complete || wantsPoster, let folder = try? session.outputFolder(id: t.id) {
                let local = URL(fileURLWithPath: folder).appendingPathComponent(media.path)
                if FileManager.default.fileExists(atPath: local.path) {
                    if complete { playable[t.id] = local }
                    if wantsPoster { posterSources[t.infoHash] = local }
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
        updateDockTile()
        updateFileProgress()
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
        let path = rootPath(id: id, folder: folder)
        if !NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        }
    }

    /// The torrent's top-level item on disk: its file for single-file
    /// torrents, else `folder` itself.
    private func rootPath(id: UInt64, folder: String) -> String {
        let torrentFiles = files[id] ?? []
        return torrentFiles.count == 1
            ? (folder as NSString).appendingPathComponent(torrentFiles[0].path)
            : folder
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
        guard let player = VideoPlayer.resolve(prefs?.videoPlayer ?? "") else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let command = player.command(for: url) else {
            NSWorkspace.shared.open([url], withApplicationAt: player.appURL, configuration: .init()) { _, error in
                guard let error else { return }
                Task { @MainActor in
                    self.sessionHolder?.errorMessage = "Couldn't open in \(player.name): \(errorDetail(error))"
                }
            }
            return
        }
        let proc = Process()
        proc.executableURL = command.executable
        proc.arguments = command.arguments
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

    /// Badge = active download count; progress bar = combined progress of
    /// those downloads.
    private func updateDockTile() {
        let active = downloading
        let badge = active.isEmpty ? "" : "\(active.count)"
        let total = active.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let done = active.reduce(UInt64(0)) { $0 + $1.downloadedBytes }
        let percent: Int? = active.isEmpty ? nil : total > 0 ? Int(Double(done) / Double(total) * 100) : 0
        guard badge != lastBadge || percent != lastDockPercent else { return }
        lastBadge = badge
        lastDockPercent = percent

        let tile = NSApp.dockTile
        tile.badgeLabel = badge.isEmpty ? nil : badge
        if let percent {
            if dockProgress == nil {
                let view = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
                tile.contentView = view
                dockProgress = view
            }
            dockProgress?.fraction = Double(percent) / 100
        } else {
            tile.contentView = nil
            dockProgress = nil
        }
        tile.display()
    }

    /// Publish each active download's progress on its top-level item so
    /// Finder and the Dock's Downloads stack draw a progress bar on it.
    private func updateFileProgress() {
        let active = Dictionary(uniqueKeysWithValues: downloading.map { ($0.id, $0) })
        for (id, progress) in fileProgress where active[id] == nil {
            progress.unpublish()
            fileProgress[id] = nil
        }
        for t in active.values where t.totalBytes > 0 {
            if fileProgress[t.id] == nil {
                guard let folder = try? sessionHolder?.session?.outputFolder(id: t.id) else { continue }
                let path = rootPath(id: t.id, folder: folder)
                // librqbit creates the files once the torrent starts; retry next poll.
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let progress = Progress(totalUnitCount: Int64(t.totalBytes))
                progress.kind = .file
                progress.fileOperationKind = .downloading
                progress.fileURL = URL(fileURLWithPath: path)
                progress.isCancellable = false
                progress.publish()
                fileProgress[t.id] = progress
            }
            fileProgress[t.id]?.totalUnitCount = Int64(t.totalBytes)
            fileProgress[t.id]?.completedUnitCount = Int64(t.downloadedBytes)
        }
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

/// App icon with a progress bar over its lower part, for the Dock tile.
private final class DockProgressView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        // Covers the artwork's bottom edge (~10% up from the tile's).
        let height = bounds.height * 0.1
        let track = NSRect(
            x: bounds.width * 0.2, y: bounds.height * 0.09,
            width: bounds.width * 0.6, height: height
        )
        NSColor(white: 0.5, alpha: 0.5).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        var fill = track
        // At least a dot, so 0% still reads as a progress bar.
        fill.size.width = height + (track.width - height) * fraction
        // Matches the in-app downloading color.
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
    }
}

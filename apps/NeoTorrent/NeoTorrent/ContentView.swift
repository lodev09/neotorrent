import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct ContentView: View {
    @Environment(SessionHolder.self) private var sessionHolder
    @Environment(Preferences.self) private var prefs
    @State private var magnetURI: String = ""
    @State private var addError: String?
    @State private var torrents: [TorrentSnapshot] = []
    @State private var isAdding = false
    @State private var expandedIDs: Set<UInt64> = []
    @State private var notifiedFinishedIDs: Set<UInt64> = []
    /// Torrents we've already decided about for auto-play. Includes torrents
    /// loaded from persistence at launch (we don't auto-play those).
    @State private var consideredAutoPlayIDs: Set<UInt64> = []
    /// Set after the first refresh so we don't auto-play resumed torrents.
    @State private var didInitializeAutoPlayBaseline = false

    private var totalDownBps: UInt64 { torrents.reduce(0) { $0 + $1.downloadBps } }
    private var totalUpBps: UInt64 { torrents.reduce(0) { $0 + $1.uploadBps } }
    private var activeCount: Int { torrents.filter { !$0.isFinished }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBar
            Divider()
            addBar
            Divider()
            if let err = sessionHolder.startupError {
                Label(err, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .padding()
            } else if torrents.isEmpty {
                emptyState
            } else {
                torrentList
            }
        }
        .onDrop(of: [.fileURL], delegate: TorrentFileDropDelegate(handler: handleDroppedFiles))
        .task { await pollLoop() }
        .task { await requestNotificationAuth() }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").foregroundStyle(.blue)
                Text(formatRate(totalDownBps))
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").foregroundStyle(.orange)
                Text(formatRate(totalUpBps))
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            Spacer()
            if torrents.isEmpty {
                Text("Ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(activeCount) active / \(torrents.count) total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste magnet URI…", text: $magnetURI)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await add() } }
                Button {
                    Task { await add() }
                } label: {
                    if isAdding {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Adding…")
                        }
                    } else {
                        Label("Add", systemImage: "plus.circle.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(magnetURI.isEmpty || isAdding || sessionHolder.session == nil)
            }
            if let err = addError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No torrents")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Paste a magnet URI or drop a .torrent file")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var torrentList: some View {
        List(torrents, id: \.id) { t in
            TorrentRow(
                torrent: t,
                expanded: expandedIDs.contains(t.id),
                onToggle: { toggleExpanded(t.id) },
                onPause: { Task { try? await sessionHolder.session?.pause(id: t.id) } },
                onResume: { Task { try? await sessionHolder.session?.resume(id: t.id) } },
                onRemove: { deleteFiles in
                    Task { try? await sessionHolder.session?.remove(id: t.id, deleteFiles: deleteFiles) }
                },
                onReveal: { revealInFinder(id: t.id) },
                onPlay: { file in
                    guard let session = sessionHolder.session else { return }
                    openPlayerWindow(session: session, torrentID: t.id, file: file)
                },
                onToggleFile: { file, isSelected in
                    Task { await toggleFile(torrentID: t.id, file: file, isSelected: isSelected) }
                },
                files: { sessionHolder.session.flatMap { try? $0.files(id: t.id) } ?? [] }
            )
            .padding(.vertical, 6)
        }
        .listStyle(.inset)
    }

    private func toggleExpanded(_ id: UInt64) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    private func revealInFinder(id: UInt64) {
        guard let session = sessionHolder.session,
              let path = try? session.outputFolder(id: id) else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func add() async {
        guard let session = sessionHolder.session else { return }
        let uri = magnetURI
        isAdding = true
        addError = nil
        defer { isAdding = false }
        do {
            _ = try await session.addMagnet(uri: uri)
            magnetURI = ""
            await refresh()
        } catch {
            addError = error.localizedDescription
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        Task {
            guard let session = sessionHolder.session else { return }
            for url in urls where url.pathExtension.lowercased() == "torrent" {
                let uri = url.isFileURL ? url.path : url.absoluteString
                do { _ = try await session.addMagnet(uri: uri) } catch {
                    addError = error.localizedDescription
                }
            }
            await refresh()
        }
    }

    private func refresh() async {
        guard let session = sessionHolder.session else { return }
        let updated = session.list()

        // First refresh: snapshot the existing IDs so resumed torrents don't
        // trigger auto-play. They've been "considered" already.
        if !didInitializeAutoPlayBaseline {
            consideredAutoPlayIDs = Set(updated.map { $0.id })
            didInitializeAutoPlayBaseline = true
        }

        for t in updated {
            // Newly-finished → completion notification + sound.
            if t.isFinished && !notifiedFinishedIDs.contains(t.id) {
                if let prev = torrents.first(where: { $0.id == t.id }), !prev.isFinished {
                    postCompletionNotification(for: t)
                    if prefs.completionSound {
                        NSSound(named: "Glass")?.play()
                    }
                }
                notifiedFinishedIDs.insert(t.id)
            }

            // Auto-play newly-added torrents once metadata resolves.
            if prefs.autoPlay
                && !consideredAutoPlayIDs.contains(t.id)
                && !t.isFinished
            {
                if let files = try? session.files(id: t.id), !files.isEmpty {
                    if let playable = files.first(where: { $0.isPlayable && $0.selected }) {
                        openPlayerWindow(session: session, torrentID: t.id, file: playable)
                    }
                    consideredAutoPlayIDs.insert(t.id)
                }
            }
        }

        torrents = updated
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func toggleFile(torrentID: UInt64, file: TorrentFile, isSelected: Bool) async {
        guard let session = sessionHolder.session,
              let current = try? session.files(id: torrentID) else { return }
        var indices = current
            .filter { $0.index == file.index ? isSelected : $0.selected }
            .map { $0.index }
        // Ensure at least one file remains selected — librqbit treats an empty
        // set as "download nothing" which can leave the torrent in a weird state.
        if indices.isEmpty {
            indices = current.map { $0.index }
        }
        try? await session.setOnlyFiles(id: torrentID, indices: indices)
    }

    private func requestNotificationAuth() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
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

struct TorrentRow: View {
    let torrent: TorrentSnapshot
    let expanded: Bool
    let onToggle: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: (Bool) -> Void
    let onReveal: () -> Void
    let onPlay: (TorrentFile) -> Void
    let onToggleFile: (TorrentFile, Bool) -> Void
    let files: () -> [TorrentFile]

    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Image(systemName: iconName).foregroundStyle(iconColor)
                Text(torrent.name ?? "fetching metadata…")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(torrent.state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.gray.opacity(0.15), in: Capsule())
                controls
            }
            ProgressView(value: torrent.progress)
                .progressViewStyle(.linear)
            HStack(spacing: 16) {
                stat("Progress", String(format: "%.1f%%", torrent.progress * 100))
                stat("Down", formatRate(torrent.downloadBps))
                stat("Up", formatRate(torrent.uploadBps))
                stat("Peers", "\(torrent.peersLive)/\(torrent.peersSeen)")
                Spacer()
                Text("\(formatBytes(torrent.downloadedBytes)) / \(formatBytes(torrent.totalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if expanded {
                FileList(files: files(), onPlay: onPlay, onToggle: onToggleFile)
                    .padding(.top, 4)
            }
        }
        .confirmationDialog(
            "Remove \(torrent.name ?? "torrent")?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove (keep files)") { onRemove(false) }
            Button("Remove + delete files", role: .destructive) { onRemove(true) }
            Button("Cancel", role: .cancel) { }
        }
    }

    @ViewBuilder
    private var controls: some View {
        let paused = torrent.state.lowercased() == "paused"
        Button(action: paused ? onResume : onPause) {
            Image(systemName: paused ? "play.fill" : "pause.fill")
        }
        .help(paused ? "Resume" : "Pause")
        Button(action: onReveal) {
            Image(systemName: "folder")
        }
        .help("Reveal in Finder")
        Button {
            confirmingRemove = true
        } label: {
            Image(systemName: "trash")
        }
        .help("Remove torrent")
    }

    private var iconName: String {
        if torrent.isFinished { return "checkmark.circle.fill" }
        if torrent.state.lowercased() == "paused" { return "pause.circle" }
        return "arrow.down.circle"
    }

    private var iconColor: Color {
        if torrent.isFinished { return .green }
        if torrent.state.lowercased() == "paused" { return .secondary }
        return .blue
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct FileList: View {
    let files: [TorrentFile]
    let onPlay: (TorrentFile) -> Void
    let onToggle: (TorrentFile, Bool) -> Void

    var body: some View {
        if files.isEmpty {
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                Text("File list available after metadata resolves")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.leading, 22)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(files, id: \.index) { f in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { f.selected },
                            set: { onToggle(f, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        Image(systemName: fileIcon(f))
                            .foregroundStyle(fileIconColor(f))
                            .imageScale(.small)
                        Text(f.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(f.selected ? .primary : .tertiary)
                            .strikethrough(!f.selected)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if f.isPlayable && f.selected {
                            Button {
                                onPlay(f)
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .help("Stream this file")
                        }
                        Spacer()
                        Text(progressText(f))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 22)
        }
    }

    private func fileIcon(_ f: TorrentFile) -> String {
        if !f.selected { return "minus.circle" }
        return f.downloaded >= f.length ? "checkmark.circle.fill" : "doc"
    }

    private func fileIconColor(_ f: TorrentFile) -> Color {
        if !f.selected { return .gray.opacity(0.6) }
        return f.downloaded >= f.length ? .green : .secondary
    }

    private func progressText(_ f: TorrentFile) -> String {
        if !f.selected {
            return "skipped (\(formatBytes(f.length)))"
        }
        if f.downloaded >= f.length {
            return formatBytes(f.length)
        }
        return "\(formatBytes(f.downloaded)) / \(formatBytes(f.length))"
    }
}

struct TorrentFileDropDelegate: DropDelegate {
    let handler: ([URL]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        var collected: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { collected.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) { handler(collected) }
        return true
    }
}

private func formatBytes(_ b: UInt64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    f.countStyle = .file
    return f.string(fromByteCount: Int64(b))
}

private func formatRate(_ bps: UInt64) -> String {
    "\(formatBytes(bps))/s"
}

#Preview {
    ContentView()
        .environment(SessionHolder())
        .frame(width: 760, height: 540)
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct ContentView: View {
    @Environment(SessionHolder.self) private var sessionHolder
    @Environment(Preferences.self) private var prefs
    @State private var addError: String?
    @State private var torrents: [TorrentSnapshot] = []
    @State private var expandedIDs: Set<UInt64> = []
    @State private var notifiedFinishedIDs: Set<UInt64> = []

    private var activeCount: Int { torrents.filter { !$0.isFinished }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = sessionHolder.startupError {
                Label(err, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .padding()
            } else {
                torrentList
            }
            if let err = addError {
                HStack(spacing: 6) {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Spacer()
                    Button {
                        addError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .navigationTitle("NeoTorrent")
        .navigationSubtitle(torrents.isEmpty ? "" : "\(activeCount) active / \(torrents.count) total")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: pickTorrentFile) {
                    Label("Add", systemImage: "plus")
                }
                .help("Add .torrent file")
                .disabled(sessionHolder.session == nil)
            }
        }
        .onDrop(of: [.fileURL], delegate: TorrentFileDropDelegate(handler: handleDroppedFiles))
        .onPasteCommand(of: [UTType.url.identifier, UTType.plainText.identifier], perform: handlePastedItems)
        .task { await pollLoop() }
        .task { await requestNotificationAuth() }
    }

    private var torrentList: some View {
        VStack(spacing: 10) {
            ForEach(sessionHolder.pendingAdds) { p in
                PendingRow(name: p.name)
            }
            ForEach(torrents, id: \.id) { t in
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
                    onToggleFile: { file, isSelected in
                        Task { await toggleFile(torrentID: t.id, file: file, isSelected: isSelected) }
                    },
                    files: { sessionHolder.session.flatMap { try? $0.files(id: t.id) } ?? [] }
                )
            }
            dropHint
        }
        .padding(12)
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop a .torrent file or paste a magnet link")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, torrents.isEmpty ? 56 : 20)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [5])
                )
        )
    }

    private func toggleExpanded(_ id: UInt64) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    private func revealInFinder(id: UInt64) {
        guard let session = sessionHolder.session,
              let path = try? session.outputFolder(id: id) else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func pickTorrentFile() {
        guard sessionHolder.session != nil else { return }
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [type]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose .torrent file(s) to add"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        addError = nil
        Task {
            for url in urls {
                do { _ = try await sessionHolder.add(uri: url.path) }
                catch { addError = error.localizedDescription }
            }
            await refresh()
        }
    }

    private func handlePastedItems(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let raw = obj as? String else { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { @MainActor in
                    addError = nil
                    do {
                        _ = try await sessionHolder.add(uri: trimmed)
                        await refresh()
                    } catch {
                        addError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        Task {
            addError = nil
            for url in urls where url.pathExtension.lowercased() == "torrent" {
                let uri = url.isFileURL ? url.path : url.absoluteString
                do { _ = try await sessionHolder.add(uri: uri) } catch {
                    addError = error.localizedDescription
                }
            }
            await refresh()
        }
    }

    private func refresh() async {
        guard let session = sessionHolder.session else { return }
        let updated = session.list()

        for t in updated {
            if t.isFinished && !notifiedFinishedIDs.contains(t.id) {
                if let prev = torrents.first(where: { $0.id == t.id }), !prev.isFinished {
                    postCompletionNotification(for: t)
                    if prefs.completionSound {
                        NSSound(named: "Glass")?.play()
                    }
                }
                notifiedFinishedIDs.insert(t.id)
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
    let onToggleFile: (TorrentFile, Bool) -> Void
    let files: () -> [TorrentFile]

    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(stateColor)
                Text(torrent.name ?? "fetching metadata…")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statePill
                controls
            }
            ProgressView(value: torrent.progress)
                .progressViewStyle(.linear)
                .tint(stateColor)
            HStack(spacing: 18) {
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
                Divider()
                FileList(files: files(), onToggle: onToggleFile)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
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

    private var statePill: some View {
        Text(torrent.state)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(stateColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.15), in: Capsule())
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
        if torrent.state.lowercased() == "paused" { return "pause.circle.fill" }
        return "arrow.down.circle.fill"
    }

    private var stateColor: Color {
        if torrent.isFinished { return .green }
        if torrent.state.lowercased() == "paused" { return .gray }
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

struct PendingRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Adding…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
}

struct FileList: View {
    let files: [TorrentFile]
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
        let box = URLBox()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { box.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) { handler(box.snapshot()) }
        return true
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    func snapshot() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
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

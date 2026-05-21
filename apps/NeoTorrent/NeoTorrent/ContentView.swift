import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct ContentView: View {
    @Environment(SessionHolder.self) private var sessionHolder
    @Environment(Preferences.self) private var prefs
    @State private var torrents: [TorrentSnapshot] = []
    @State private var expandedIDs: Set<UInt64> = []
    @State private var notifiedFinishedIDs: Set<UInt64> = []
    @State private var removingIDs: Set<UInt64> = []
    @State private var didInitialLoad = false


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = sessionHolder.startupError {
                Label(err, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .padding()
            } else {
                torrentList
            }
            if let err = sessionHolder.addError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        sessionHolder.addError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.regularMaterial)
                .overlay(Divider(), alignment: .top)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sessionHolder.addError)
        .navigationTitle("NeoTorrent")
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
        .task(id: sessionHolder.addError) {
            guard sessionHolder.addError != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            sessionHolder.addError = nil
        }
    }

    private var torrentList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(torrents, id: \.id) { t in
                    TorrentRow(
                        torrent: t,
                        expanded: expandedIDs.contains(t.id),
                        onToggle: { toggleExpanded(t.id) },
                        onPause: {
                            playSound("Morse")
                            Task { try? await sessionHolder.session?.pause(id: t.id) }
                        },
                        onResume: {
                            playSound("Morse")
                            Task { try? await sessionHolder.session?.resume(id: t.id) }
                        },
                        onRemove: { deleteFiles in
                            playSound("Bottle")
                            removingIDs.insert(t.id)
                            torrents.removeAll { $0.id == t.id }
                            notifiedFinishedIDs.remove(t.id)
                            Task {
                                try? await sessionHolder.session?.remove(id: t.id, deleteFiles: deleteFiles)
                                removingIDs.remove(t.id)
                            }
                        },
                        onReveal: { revealInFinder(id: t.id) },
                        onToggleFile: { file, isSelected in
                            Task { await toggleFile(torrentID: t.id, file: file, isSelected: isSelected) }
                        },
                        files: { sessionHolder.session.flatMap { try? $0.files(id: t.id) } ?? [] }
                    )
                }
                ForEach(sessionHolder.pendingAdds) { p in
                    PendingRow(name: p.name, onRemove: {
                        playSound("Bottle")
                        sessionHolder.cancelPending(p.id)
                    })
                }
                dropHint
            }
            .padding([.horizontal, .bottom], 12)
        }
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
        .padding(.vertical, 36)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
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
        sessionHolder.addError = nil
        Task {
            for url in urls {
                do { _ = try await sessionHolder.add(uri: url.path) }
                catch { sessionHolder.addError = (error as? AddTorrentError)?.errorDescription ?? error.localizedDescription }
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
                    sessionHolder.addError = nil
                    do {
                        _ = try await sessionHolder.add(uri: trimmed)
                        await refresh()
                    } catch {
                        sessionHolder.addError = (error as? AddTorrentError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        Task {
            sessionHolder.addError = nil
            for url in urls where url.pathExtension.lowercased() == "torrent" {
                let uri = url.isFileURL ? url.path : url.absoluteString
                do { _ = try await sessionHolder.add(uri: uri) } catch {
                    sessionHolder.addError = (error as? AddTorrentError)?.errorDescription ?? error.localizedDescription
                }
            }
            await refresh()
        }
    }

    private func refresh() async {
        guard let session = sessionHolder.session else { return }
        let updated = session.list()
        let previousIDs = Set(torrents.map { $0.id })
        let newlyAdded = updated.filter { !previousIDs.contains($0.id) }

        for t in updated {
            if t.isFinished && !notifiedFinishedIDs.contains(t.id) {
                if let prev = torrents.first(where: { $0.id == t.id }), !prev.isFinished {
                    postCompletionNotification(for: t)
                    playSound("Glass")
                }
                notifiedFinishedIDs.insert(t.id)
            }
        }

        torrents = updated
            .filter { !removingIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        sessionHolder.reconcilePending(against: Set(updated.map { $0.id }))

        if didInitialLoad && !newlyAdded.isEmpty {
            playSound("Pop")
        }
        didInitialLoad = true
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

    private func playSound(_ name: String) {
        guard prefs.playSounds else { return }
        NSSound(named: name)?.play()
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
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: paused ? onResume : onPause) {
                        Image(systemName: iconName)
                            .font(.title2)
                            .foregroundStyle(stateColor)
                    }
                    .buttonStyle(.plain)
                    .help(paused ? "Resume" : "Pause")
                    Text(torrent.name ?? "fetching metadata…")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    controls
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(isHovered)
                }
                .frame(height: 24)
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        ProgressView(value: torrent.progress)
                            .progressViewStyle(.linear)
                            .tint(stateColor)
                            .frame(width: 100)
                        Text(String(format: "%.0f%%", torrent.progress * 100))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                    }
                    .fixedSize()
                    if paused {
                        Text("Paused")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        stat("Down", formatRate(torrent.downloadBps))
                        stat("Up", formatRate(torrent.uploadBps))
                        stat("Peers", "\(torrent.peersLive)/\(torrent.peersSeen)")
                        Spacer()
                        Text("\(formatBytes(torrent.downloadedBytes)) / \(formatBytes(torrent.totalBytes))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            if expanded {
                FileList(files: files(), onToggle: onToggleFile)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
        .onHover { isHovered = $0 }
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

    private var paused: Bool { torrent.state.lowercased() == "paused" }

    @ViewBuilder
    private var controls: some View {
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
        return paused ? "arrow.clockwise.circle.fill" : "pause.circle.fill"
    }

    private var stateColor: Color {
        if torrent.isFinished { return .green }
        if torrent.state.lowercased() == "paused" { return .gray }
        return .blue
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct PendingRow: View {
    let name: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .help("Cancel add")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .frame(height: 24)
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .frame(width: 100)
                    .fixedSize()
                Text("Adding…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .cardChrome()
        .onHover { isHovered = $0 }
    }
}

extension View {
    func cardChrome() -> some View {
        self
            .padding(14)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
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
        } else {
            let showCheckbox = files.count > 1
            VStack(alignment: .leading, spacing: 3) {
                ForEach(files, id: \.index) { f in
                    HStack(spacing: 6) {
                        if showCheckbox {
                            Toggle("", isOn: Binding(
                                get: { f.selected },
                                set: { onToggle(f, $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        }
                        Image(systemName: fileIcon(f))
                            .foregroundStyle(fileIconColor(f))
                        Text(f.path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(f.selected ? .primary : .tertiary)
                            .strikethrough(!f.selected)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(progressText(f))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
    f.allowsNonnumericFormatting = false
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

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import UserNotifications

struct ContentView: View {
    @Environment(SessionHolder.self) private var sessionHolder
    @Environment(Preferences.self) private var prefs
    @Environment(PosterStore.self) private var posters
    @State private var torrents: [TorrentSnapshot] = []
    @State private var expandedIDs: Set<UInt64> = []
    @State private var notifiedFinishedIDs: Set<UInt64> = []
    @State private var removingIDs: Set<UInt64> = []
    @State private var playableURLs: [UInt64: URL] = [:]
    @State private var didInitialLoad = false
    @FocusState private var paneFocused: Bool


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
        .focusable()
        .focusEffectDisabled()
        .focused($paneFocused)
        .task { paneFocused = true }
        .onDrop(of: [.fileURL], delegate: TorrentFileDropDelegate(handler: handleDroppedFiles))
        .onPasteCommand(of: [UTType.url.identifier, UTType.plainText.identifier], perform: handlePastedItems)
        .onReceive(NotificationCenter.default.publisher(for: .neotorrentPasteFromClipboard)) { _ in
            pasteFromClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .neotorrentOpenTorrentFile)) { _ in
            pickTorrentFile()
        }
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
                        files: { sessionHolder.session.flatMap { try? $0.files(id: t.id) } ?? [] },
                        playURL: playableURLs[t.id],
                        onPlay: { url in playInVLC(url: url) },
                        poster: posters.image(for: t.infoHash)
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
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        }
    }

    private func revealInFinder(id: UInt64) {
        guard let session = sessionHolder.session,
              let path = try? session.outputFolder(id: id) else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func refreshPlayableURLs(for torrents: [TorrentSnapshot], session: NeoTorrentSession) {
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
                posters.ensure(infoHash: t.infoHash, fileURL: local)
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

    private func playInVLC(url: URL) {
        guard let vlcURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: vlcURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
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
                catch { sessionHolder.addError = friendlyAddError(error) }
            }
            await refresh()
        }
    }

    private func handlePastedItems(_ providers: [NSItemProvider]) {
        pasteFromClipboard()
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        var candidates: [String] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            candidates.append(contentsOf: urls.map { $0.absoluteString })
        }
        if let strings = pb.readObjects(forClasses: [NSString.self]) as? [String] {
            candidates.append(contentsOf: strings)
        }
        var seen: Set<String> = []
        Task { @MainActor in
            sessionHolder.addError = nil
            for raw in candidates {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                do {
                    _ = try await sessionHolder.add(uri: trimmed)
                } catch {
                    sessionHolder.addError = friendlyAddError(error)
                }
            }
            await refresh()
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        Task {
            sessionHolder.addError = nil
            for url in urls where url.pathExtension.lowercased() == "torrent" {
                let uri = url.isFileURL ? url.path : url.absoluteString
                do { _ = try await sessionHolder.add(uri: uri) } catch {
                    sessionHolder.addError = friendlyAddError(error)
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
        refreshPlayableURLs(for: torrents, session: session)

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
    let playURL: URL?
    let onPlay: (URL) -> Void
    let poster: NSImage?

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
                        .animation(.easeOut(duration: 0.08), value: isHovered)
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
                    if torrent.isFinished {
                        Text("Completed")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else if paused {
                        Text("Paused")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        stat("arrow.down", formatRate(torrent.downloadBps))
                        stat("arrow.up", formatRate(torrent.uploadBps))
                        stat("person.2.fill", "\(torrent.peersLive)/\(torrent.peersSeen)")
                        if !torrent.isFinished, torrent.downloadBps > 0, torrent.totalBytes > torrent.downloadedBytes {
                            stat("clock", formatETA(remaining: torrent.totalBytes - torrent.downloadedBytes, bps: torrent.downloadBps))
                        }
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
                FileList(files: files(), onToggle: onToggleFile, onCollapse: onToggle)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(.secondary)
                .frame(width: 32, height: 4)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
                .opacity(isHovered ? 0.6 : 0)
                .allowsHitTesting(isHovered)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .foregroundStyle(poster != nil ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .scaledToFill()
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.7), .black.opacity(0.45), .black.opacity(0.65)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else {
                Rectangle().fill(.thickMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onContinuousHover { phase in
            switch phase {
            case .active: isHovered = true
            case .ended:  isHovered = false
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

    private var paused: Bool { torrent.state.lowercased() == "paused" }

    @ViewBuilder
    private var controls: some View {
        if let playURL {
            Button { onPlay(playURL) } label: {
                Image(systemName: "play.fill")
            }
            .help("Play in VLC")
        }
        Button(action: onReveal) {
            Image(systemName: "folder")
        }
        .help("Reveal in Finder")
        Button {
            if torrent.isFinished {
                onRemove(false)
            } else {
                confirmingRemove = true
            }
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

    private func stat(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
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
                .animation(.easeOut(duration: 0.08), value: isHovered)
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
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onContinuousHover { phase in
            switch phase {
            case .active: isHovered = true
            case .ended:  isHovered = false
            }
        }
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
    let onCollapse: () -> Void

    // Optimistic overrides — flip instantly on click; cleared once the
    // backend's reported `selected` catches up (next poll tick).
    @State private var pending: [UInt32: Bool] = [:]

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
                    let isOn = pending[f.index] ?? f.selected
                    HStack(spacing: 6) {
                        if showCheckbox {
                            Toggle("", isOn: Binding(
                                get: { isOn },
                                set: { newValue in
                                    pending[f.index] = newValue
                                    onToggle(f, newValue)
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .allowsHitTesting(false)
                        }
                        Image(systemName: fileIcon(f, selected: isOn))
                            .foregroundStyle(fileIconColor(f, selected: isOn))
                        Text(f.path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(isOn ? .primary : .tertiary)
                            .strikethrough(!isOn)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard showCheckbox else { return }
                                let newValue = !isOn
                                pending[f.index] = newValue
                                onToggle(f, newValue)
                            }
                        Spacer()
                        Text(progressText(f, selected: isOn))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onCollapse() }
                }
            }
            .onChange(of: files.map { $0.selected }) {
                pending = pending.filter { idx, val in
                    files.first(where: { $0.index == idx })?.selected != val
                }
            }
        }
    }

    private func fileIcon(_ f: TorrentFile, selected: Bool) -> String {
        if !selected { return "minus.circle" }
        return f.downloaded >= f.length ? "checkmark.circle.fill" : "doc"
    }

    private func fileIconColor(_ f: TorrentFile, selected: Bool) -> Color {
        if !selected { return .gray.opacity(0.6) }
        return f.downloaded >= f.length ? .green : .secondary
    }

    private func progressText(_ f: TorrentFile, selected: Bool) -> String {
        if !selected {
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

private func formatETA(remaining: UInt64, bps: UInt64) -> String {
    guard bps > 0 else { return "—" }
    let seconds = remaining / bps
    if seconds < 60 { return "<1m" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let mins = minutes % 60
    if hours < 24 { return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m" }
    let days = hours / 24
    let hrs = hours % 24
    return hrs == 0 ? "\(days)d" : "\(days)d \(hrs)h"
}

#Preview {
    ContentView()
        .environment(SessionHolder())
        .frame(width: 760, height: 540)
}

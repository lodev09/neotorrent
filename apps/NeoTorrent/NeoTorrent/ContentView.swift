import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(SessionHolder.self) private var sessionHolder
    @Environment(Preferences.self) private var prefs
    @Environment(PosterStore.self) private var posters
    @Environment(TorrentStore.self) private var store
    @State private var expandedIDs: Set<UInt64> = []
    @FocusState private var paneFocused: Bool


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = sessionHolder.startupError {
                ContentUnavailableView {
                    Label("Engine Didn't Start", systemImage: "exclamationmark.octagon")
                } description: {
                    Text(err)
                } actions: {
                    Button("Try Again") {
                        Task { await sessionHolder.start(prefs: prefs, store: store, posters: posters) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                torrentList
            }
            if let err = sessionHolder.errorMessage {
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
                        sessionHolder.errorMessage = nil
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sessionHolder.errorMessage)
        .navigationTitle("NeoTorrent")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: sessionHolder.pickAndAddTorrentFiles) {
                    Label("Add", systemImage: "plus")
                }
                .help("Add .torrent file")
                .disabled(sessionHolder.session == nil)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .focusable()
        .focusEffectDisabled()
        .focused($paneFocused)
        .task { paneFocused = true }
        .onDrop(of: [.fileURL, .url, .plainText], delegate: TorrentDropDelegate(handler: sessionHolder.addDropped))
        .onPasteCommand(of: [UTType.url.identifier, UTType.plainText.identifier]) { _ in
            sessionHolder.addFromClipboard()
        }
        .task(id: sessionHolder.errorMessage) {
            guard sessionHolder.errorMessage != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            sessionHolder.errorMessage = nil
        }
    }

    private var torrentList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(store.torrents, id: \.id) { t in
                    TorrentRow(
                        torrent: t,
                        expanded: expandedIDs.contains(t.id),
                        onToggle: { toggleExpanded(t.id) },
                        onPause: { store.pause(id: t.id) },
                        onResume: { store.resume(id: t.id) },
                        onRemove: { deleteFiles in
                            store.remove(id: t.id, deleteFiles: deleteFiles)
                        },
                        onReveal: { store.revealInFinder(id: t.id) },
                        onToggleFile: { file, isSelected in
                            store.setFile(file, selected: isSelected, torrentID: t.id)
                        },
                        files: store.files[t.id] ?? [],
                        playURL: store.playableURLs[t.id],
                        isPlaying: store.playingTorrentID == t.id,
                        onPlay: { store.togglePlayback(id: t.id) },
                        poster: posters.image(for: t.infoHash)
                    )
                }
                ForEach(sessionHolder.pendingAdds) { p in
                    PendingRow(name: p.name, onRemove: {
                        store.playSound("Bottle")
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
            Text("Drop a .torrent file or magnet link, or paste one")
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
    let files: [TorrentFile]
    let playURL: URL?
    let isPlaying: Bool
    let onPlay: () -> Void
    let poster: NSImage?

    @State private var confirmingRemove = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: torrent.isErrored || paused ? onResume : onPause) {
                        Image(systemName: iconName)
                            .font(.title2)
                            .foregroundStyle(stateColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(torrent.isChecking)
                    .help(primaryActionHelp)
                    Text(torrent.name ?? "fetching metadata…")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    controls
                        .opacity((isHovered || isPlaying) ? 1 : 0)
                        .allowsHitTesting(isHovered || isPlaying)
                        .animation(.easeOut(duration: 0.08), value: isHovered)
                        .animation(.easeOut(duration: 0.08), value: isPlaying)
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
                    if torrent.isErrored {
                        Text("Error: \(torrent.error ?? "unknown")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(torrent.error ?? "")
                        Spacer()
                    } else if torrent.isChecking {
                        Text("Checking files…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else if torrent.isFinished {
                        Text(paused ? "Completed · Paused" : "Completed")
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
                        if torrent.downloadBps > 0, torrent.totalBytes > torrent.downloadedBytes {
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
                FileList(files: files, onToggle: onToggleFile, onCollapse: onToggle)
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
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .glassCard(enabled: poster == nil, cornerRadius: 12)
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

    private var paused: Bool { torrent.isPaused }

    @ViewBuilder
    private var controls: some View {
        if playURL != nil {
            Button { onPlay() } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .foregroundStyle(isPlaying ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            .help(isPlaying ? "Stop VLC" : TorrentStore.vlcBinary == nil ? "Stream in browser" : "Play in VLC")
        }
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
        if torrent.isErrored { return "exclamationmark.circle.fill" }
        if torrent.isChecking { return "arrow.triangle.2.circlepath.circle.fill" }
        if torrent.isFinished { return "checkmark.circle.fill" }
        return paused ? "arrow.clockwise.circle.fill" : "pause.circle.fill"
    }

    private var stateColor: Color {
        if torrent.isErrored { return .red }
        if torrent.isChecking { return .gray }
        if torrent.isFinished { return paused ? .gray : .green }
        return paused ? .gray : .blue
    }

    private var primaryActionHelp: String {
        if torrent.isErrored { return "Retry" }
        if torrent.isChecking { return "Checking files…" }
        if torrent.isFinished { return paused ? "Resume seeding" : "Pause seeding" }
        return paused ? "Resume" : "Pause"
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
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .frame(width: 100)
                    .fixedSize()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(enabled: true, cornerRadius: 12)
        .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onContinuousHover { phase in
            switch phase {
            case .active: isHovered = true
            case .ended:  isHovered = false
            }
        }
    }
}

struct FileList: View {
    let files: [TorrentFile]
    let onToggle: (TorrentFile, Bool) -> Void
    let onCollapse: () -> Void

    var body: some View {
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard showCheckbox else { return }
                            onToggle(f, !f.selected)
                        }
                    Spacer()
                    Text(progressText(f))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onCollapse() }
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

/// Collects dropped .torrent files, magnet/http links, and plain text.
struct TorrentDropDelegate: DropDelegate {
    let handler: @MainActor ([String]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let box = StringBox()
        let group = DispatchGroup()
        for p in info.itemProviders(for: [.fileURL, .url, .plainText]) {
            group.enter()
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { box.append(url.absoluteString) }
                    group.leave()
                }
            } else {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    if let text { box.append(text) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { handler(box.snapshot()) }
        }
        return true
    }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String] = []
    func append(_ s: String) { lock.lock(); strings.append(s); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return strings }
}

extension View {
    @ViewBuilder
    func glassCard(enabled: Bool, cornerRadius: CGFloat) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                self.glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self.background(.thickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self
        }
    }
}

#Preview {
    ContentView()
        .environment(SessionHolder())
        .environment(Preferences())
        .environment(PosterStore())
        .environment(TorrentStore())
        .frame(width: 760, height: 540)
}

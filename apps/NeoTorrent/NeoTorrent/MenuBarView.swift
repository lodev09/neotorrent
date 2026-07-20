import SwiftUI
import AppKit

struct MenuBarLabel: View {
    let store: TorrentStore

    // Menu bar labels need a template NSImage with an explicit point size —
    // SwiftUI resizing/rendering modifiers are unreliable inside MenuBarExtra.
    @MainActor private static let icon: NSImage = {
        let img = NSImage(named: "MenuBarIcon") ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: 15, height: 15)
        return img
    }()

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon)
            if let progress = store.aggregateProgress {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(TorrentStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    // MenuBarExtra window content doesn't reliably re-render on @Observable
    // changes (it only refreshes when the label happens to change). Tick a
    // local @State at the store's poll cadence to force fresh body passes.
    @State private var tick = false

    // The MenuBarExtra panel sizes to the content's *ideal* height, and a
    // ScrollView's ideal height is zero — so it collapses and the list never
    // shows. Measure the list content and size the ScrollView explicitly.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider()
                .padding(.horizontal, 14)
            if store.torrents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.torrents, id: \.id) { t in
                            MenuBarTorrentRow(
                                torrent: t,
                                canPlay: store.playableURLs[t.id] != nil,
                                isPlaying: store.playingTorrentID == t.id,
                                onPlay: { store.togglePlayback(id: t.id) },
                                onPause: { store.pause(id: t.id) },
                                onResume: { store.resume(id: t.id) },
                                onReveal: { store.revealInFinder(id: t.id) },
                                onRemove: { deleteFiles in store.remove(id: t.id, deleteFiles: deleteFiles) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        listHeight = height
                    }
                }
                .frame(height: min(listHeight, 340))
            }
            Divider()
                .padding(.horizontal, 14)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(width: 380)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            tick.toggle()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NeoTorrent")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                rate("arrow.down", store.totalDownloadBps, .blue)
                rate("arrow.up", store.totalUploadBps, .green)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        let d = store.downloading.count
        if d > 0 { parts.append("\(d) downloading") }
        if store.seedingCount > 0 { parts.append("\(store.seedingCount) seeding") }
        if store.pausedCount > 0 { parts.append("\(store.pausedCount) paused") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }

    private func rate(_ icon: String, _ bps: UInt64, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(bps > 0 ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
            Text(formatRate(bps))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No torrents")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                dismiss()
            } label: {
                Label("Open NeoTorrent", systemImage: "macwindow")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit NeoTorrent")
        }
    }
}

private struct MenuBarTorrentRow: View {
    let torrent: TorrentSnapshot
    let canPlay: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onReveal: () -> Void
    let onRemove: (Bool) -> Void

    @State private var isHovered = false
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if confirmingRemove {
                confirmRow
            } else {
                titleRow
            }
            ProgressView(value: torrent.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(statusColor)
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.0f%%", torrent.progress * 100))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { onReveal() }
        .onHover { isHovered = $0 }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Button(action: torrent.isPaused ? onResume : onPause) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
            .buttonStyle(.plain)
            .help(torrent.isPaused ? "Resume" : "Pause")
            Text(torrent.name ?? "Fetching metadata…")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            HStack(spacing: 12) {
                if canPlay {
                    Button(action: onPlay) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.caption2)
                            .foregroundStyle(isPlaying ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "Stop VLC" : "Stream in VLC")
                    .opacity(isHovered ? 1 : 0)
                }
                Button {
                    if torrent.isFinished {
                        onRemove(false)
                    } else {
                        confirmingRemove = true
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove torrent")
                .opacity(isHovered ? 1 : 0)
            }
            .padding(.leading, 4)
        }
    }

    // Inline remove confirmation — presentation modifiers (confirmationDialog,
    // sheets) don't work reliably inside MenuBarExtra panels.
    private var confirmRow: some View {
        HStack(spacing: 8) {
            Text("Remove?")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Keep Files") { onRemove(false) }
                .font(.caption)
            Button("Delete Files") { onRemove(true) }
                .font(.caption)
                .foregroundStyle(.red)
            Button {
                confirmingRemove = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .buttonStyle(.plain)
    }

    private var statusIcon: String {
        if torrent.isFinished { return "checkmark.circle.fill" }
        return torrent.isPaused ? "arrow.clockwise.circle.fill" : "pause.circle.fill"
    }

    private var statusColor: Color {
        if torrent.isFinished { return .green }
        return torrent.isPaused ? .gray : .blue
    }

    private var statusText: String {
        if torrent.isFinished {
            return "Complete · \(formatBytes(torrent.totalBytes))"
        }
        if torrent.isPaused { return "Paused" }
        var parts = [formatRate(torrent.downloadBps)]
        if torrent.downloadBps > 0, torrent.totalBytes > torrent.downloadedBytes {
            parts.append(formatETA(
                remaining: torrent.totalBytes - torrent.downloadedBytes,
                bps: torrent.downloadBps
            ))
        }
        parts.append("\(torrent.peersLive) peers")
        return parts.joined(separator: " · ")
    }
}

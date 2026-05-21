import SwiftUI
import AppKit

@MainActor
@Observable
final class Preferences {
    static let downloadDirKey = "preferences.downloadDir"
    static let downloadKBpsKey = "preferences.downloadKBps"
    static let uploadKBpsKey = "preferences.uploadKBps"
    static let playSoundsKey = "preferences.playSounds"

    var downloadDir: String {
        didSet { UserDefaults.standard.set(downloadDir, forKey: Self.downloadDirKey) }
    }
    /// 0 = unlimited. Kilobytes per second.
    var downloadKBps: Int {
        didSet {
            UserDefaults.standard.set(downloadKBps, forKey: Self.downloadKBpsKey)
            applyLimits()
        }
    }
    var uploadKBps: Int {
        didSet {
            UserDefaults.standard.set(uploadKBps, forKey: Self.uploadKBpsKey)
            applyLimits()
        }
    }
    /// Play a chime when a torrent finishes.
    var playSounds: Bool {
        didSet { UserDefaults.standard.set(playSounds, forKey: Self.playSoundsKey) }
    }

    var sessionDownloadDir: String = ""
    var session: NeoTorrentSession?

    static var defaultDownloadDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    init() {
        let d = UserDefaults.standard
        self.downloadDir = d.string(forKey: Self.downloadDirKey) ?? Self.defaultDownloadDir
        self.downloadKBps = d.integer(forKey: Self.downloadKBpsKey)
        self.uploadKBps = d.integer(forKey: Self.uploadKBpsKey)
        // For bools, default to true if never set.
        self.playSounds = d.object(forKey: Self.playSoundsKey) as? Bool ?? true
    }

    func attach(_ session: NeoTorrentSession, sessionDir: String) {
        self.session = session
        self.sessionDownloadDir = sessionDir
        applyLimits()
    }

    var pendingRestart: Bool {
        !sessionDownloadDir.isEmpty && downloadDir != sessionDownloadDir
    }

    private func applyLimits() {
        guard let session else { return }
        session.setRateLimits(
            downloadBps: UInt32(max(0, downloadKBps) * 1024),
            uploadBps: UInt32(max(0, uploadKBps) * 1024)
        )
    }
}

struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @State private var magnetIsDefault = DefaultAppHelper.isDefaultForMagnet
    @State private var torrentIsDefault = DefaultAppHelper.isDefaultForTorrent
    @State private var settingDefault = false

    var body: some View {
        @Bindable var bindable = prefs
        Form {
            Section("Downloads") {
                LabeledContent("Folder") {
                    HStack {
                        Text(prefs.downloadDir)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Choose…", action: chooseDir)
                        Button("Show") {
                            NSWorkspace.shared.selectFile(
                                prefs.downloadDir,
                                inFileViewerRootedAtPath: ""
                            )
                        }
                    }
                }
                if prefs.pendingRestart {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Restart NeoTorrent to apply the new folder. Existing torrents continue downloading to their original location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Bandwidth") {
                rateField("Max download", value: $bindable.downloadKBps)
                rateField("Max upload", value: $bindable.uploadKBps)
                Text("0 = unlimited. Applies immediately, session-wide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Play sound effects", isOn: $bindable.playSounds)
            }

            Section("System") {
                defaultAppRow(
                    label: "magnet: links",
                    isDefault: magnetIsDefault,
                    currentHandler: DefaultAppHelper.currentMagnetHandlerName(),
                    action: setMagnetDefault
                )
                defaultAppRow(
                    label: ".torrent files",
                    isDefault: torrentIsDefault,
                    currentHandler: DefaultAppHelper.currentTorrentHandlerName(),
                    action: setTorrentDefault
                )
                Text("macOS may prompt for confirmation the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func defaultAppRow(
        label: String,
        isDefault: Bool,
        currentHandler: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if isDefault {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("NeoTorrent is the default")
                            .font(.caption)
                    }
                } else if let h = currentHandler {
                    Text("Currently: \(h)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No default app set")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(isDefault ? "Set" : "Set as default") {
                action()
            }
            .disabled(isDefault || settingDefault)
        }
    }

    private func setMagnetDefault() {
        settingDefault = true
        Task {
            _ = await DefaultAppHelper.setAsDefaultForMagnet()
            magnetIsDefault = DefaultAppHelper.isDefaultForMagnet
            settingDefault = false
        }
    }

    private func setTorrentDefault() {
        settingDefault = true
        Task {
            _ = await DefaultAppHelper.setAsDefaultForTorrent()
            torrentIsDefault = DefaultAppHelper.isDefaultForTorrent
            settingDefault = false
        }
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.title = "Choose download folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: prefs.downloadDir)
        if panel.runModal() == .OK, let url = panel.url {
            prefs.downloadDir = url.path
        }
    }

    private func rateField(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            Text("KB/s")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

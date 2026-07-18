import SwiftUI
import AppKit

@MainActor
@Observable
final class Preferences {
    static let downloadDirKey = "preferences.downloadDir"
    static let downloadMBpsKey = "preferences.downloadMBps"
    static let uploadMBpsKey = "preferences.uploadMBps"
    static let playSoundsKey = "preferences.playSounds"
    static let showMenuBarIconKey = "preferences.showMenuBarIcon"
    static let showDockIconKey = "preferences.showDockIcon"

    var downloadDir: String {
        didSet { UserDefaults.standard.set(downloadDir, forKey: Self.downloadDirKey) }
    }
    /// 0 = unlimited. Megabytes per second.
    var downloadMBps: Int {
        didSet {
            UserDefaults.standard.set(downloadMBps, forKey: Self.downloadMBpsKey)
            applyLimits()
        }
    }
    var uploadMBps: Int {
        didSet {
            UserDefaults.standard.set(uploadMBps, forKey: Self.uploadMBpsKey)
            applyLimits()
        }
    }
    /// Play a chime when a torrent finishes.
    var playSounds: Bool {
        didSet { UserDefaults.standard.set(playSounds, forKey: Self.playSoundsKey) }
    }
    /// Show download progress in the macOS menu bar.
    var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: Self.showMenuBarIconKey)
            // Never allow both the menu bar icon and Dock icon to be hidden.
            if !showMenuBarIcon { showDockIcon = true }
        }
    }
    /// Show the Dock icon; off = menu-bar-only app.
    var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Self.showDockIconKey)
            if !showDockIcon { showMenuBarIcon = true }
            Self.applyActivationPolicy(showDockIcon: showDockIcon)
        }
    }

    var sessionDownloadDir: String = ""
    var session: NeoTorrentSession?

    static var defaultDownloadDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    init() {
        let d = UserDefaults.standard
        self.downloadDir = d.string(forKey: Self.downloadDirKey) ?? Self.defaultDownloadDir
        self.downloadMBps = d.integer(forKey: Self.downloadMBpsKey)
        self.uploadMBps = d.integer(forKey: Self.uploadMBpsKey)
        // For bools, default to true if never set.
        self.playSounds = d.object(forKey: Self.playSoundsKey) as? Bool ?? true
        self.showMenuBarIcon = d.object(forKey: Self.showMenuBarIconKey) as? Bool ?? true
        self.showDockIcon = Self.storedShowDockIcon
    }

    /// Read directly from defaults — AppDelegate needs this before Preferences exists.
    static var storedShowDockIcon: Bool {
        UserDefaults.standard.object(forKey: showDockIconKey) as? Bool ?? true
    }

    static func applyActivationPolicy(showDockIcon: Bool) {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        NSApp.activate(ignoringOtherApps: true)
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
        // Clamp before multiplying — the FFI takes UInt32 bps, so anything
        // past ~4096 MB/s would overflow (and crash on the UInt32 init).
        session.setRateLimits(
            downloadBps: UInt32(clamping: min(max(0, downloadMBps), 4095) * 1024 * 1024),
            uploadBps: UInt32(clamping: min(max(0, uploadMBps), 4095) * 1024 * 1024)
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
                rateField("Max download", value: $bindable.downloadMBps)
                rateField("Max upload", value: $bindable.uploadMBps)
                Text("0 = unlimited. Applies immediately, session-wide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Play sound effects", isOn: $bindable.playSounds)
                Toggle("Show progress in menu bar", isOn: $bindable.showMenuBarIcon)
                Toggle("Show Dock icon", isOn: $bindable.showDockIcon)
                Text("Turning off the Dock icon keeps NeoTorrent running in the menu bar only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("MB/s")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

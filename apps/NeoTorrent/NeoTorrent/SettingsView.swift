import SwiftUI
import AppKit

@MainActor
@Observable
final class Preferences {
    static let downloadDirKey = "preferences.downloadDir"
    static let downloadMBpsKey = "preferences.downloadMBps"
    static let uploadMBpsKey = "preferences.uploadMBps"
    static let playSoundsKey = "preferences.playSounds"
    static let seedRatioLimitKey = "preferences.seedRatioLimit"
    static let preventSleepKey = "preferences.preventSleep"

    /// The FFI takes UInt32 bytes/sec; 4095 MB/s is the largest that fits.
    static let maxMBps = 4095.0

    /// Where new torrents are saved. Existing torrents keep their folder.
    var downloadDir: String {
        didSet { UserDefaults.standard.set(downloadDir, forKey: Self.downloadDirKey) }
    }
    /// 0 = unlimited. Megabytes per second.
    var downloadMBps: Double {
        didSet {
            let clamped = Self.clampRate(downloadMBps)
            guard clamped == downloadMBps else {
                downloadMBps = clamped
                return
            }
            UserDefaults.standard.set(downloadMBps, forKey: Self.downloadMBpsKey)
            applyLimits()
        }
    }
    var uploadMBps: Double {
        didSet {
            let clamped = Self.clampRate(uploadMBps)
            guard clamped == uploadMBps else {
                uploadMBps = clamped
                return
            }
            UserDefaults.standard.set(uploadMBps, forKey: Self.uploadMBpsKey)
            applyLimits()
        }
    }
    /// Play a chime when a torrent finishes.
    var playSounds: Bool {
        didSet { UserDefaults.standard.set(playSounds, forKey: Self.playSoundsKey) }
    }
    /// Pause completed torrents after uploading this many times their size. 0 = never.
    var seedRatioLimit: Double {
        didSet {
            let clamped = seedRatioLimit.isFinite ? max(0, seedRatioLimit) : 0
            guard clamped == seedRatioLimit else {
                seedRatioLimit = clamped
                return
            }
            UserDefaults.standard.set(seedRatioLimit, forKey: Self.seedRatioLimitKey)
        }
    }
    /// Keep the Mac awake while anything is downloading.
    var preventSleep: Bool {
        didSet { UserDefaults.standard.set(preventSleep, forKey: Self.preventSleepKey) }
    }

    @ObservationIgnored private var session: NeoTorrentSession?

    static var defaultDownloadDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    init() {
        let d = UserDefaults.standard
        self.downloadDir = d.string(forKey: Self.downloadDirKey) ?? Self.defaultDownloadDir
        self.downloadMBps = Self.clampRate(d.double(forKey: Self.downloadMBpsKey))
        self.uploadMBps = Self.clampRate(d.double(forKey: Self.uploadMBpsKey))
        self.seedRatioLimit = d.double(forKey: Self.seedRatioLimitKey)
        // For bools, default to true if never set.
        self.playSounds = d.object(forKey: Self.playSoundsKey) as? Bool ?? true
        self.preventSleep = d.object(forKey: Self.preventSleepKey) as? Bool ?? true
    }

    func attach(_ session: NeoTorrentSession) {
        self.session = session
        applyLimits()
    }

    private static func clampRate(_ mbps: Double) -> Double {
        mbps.isFinite ? min(max(0, mbps), maxMBps) : 0
    }

    private func applyLimits() {
        session?.setRateLimits(
            downloadBps: UInt32(downloadMBps * 1024 * 1024),
            uploadBps: UInt32(uploadMBps * 1024 * 1024)
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
                Text("New torrents are saved here. Existing torrents keep their location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bandwidth") {
                numberField("Max download", value: $bindable.downloadMBps, unit: "MB/s")
                numberField("Max upload", value: $bindable.uploadMBps, unit: "MB/s")
                Text("0 = unlimited. Applies immediately, session-wide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Seeding") {
                numberField("Stop seeding at ratio", value: $bindable.seedRatioLimit, unit: "×")
                Text("Pauses a completed torrent once it has uploaded this many times its size since it was last started. 0 = seed indefinitely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Play sound effects", isOn: $bindable.playSounds)
                Toggle("Prevent sleep while downloading", isOn: $bindable.preventSleep)
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

    private func numberField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            Text(unit)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(width: 36, alignment: .leading)
        }
    }
}

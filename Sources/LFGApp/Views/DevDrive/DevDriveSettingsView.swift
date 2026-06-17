import SwiftUI
import LFGKit

// MARK: - DevDriveSettingsView

/// DevDrive preferences tab shown in the app Settings scene.
///
/// Covers:
/// - Fleet file path (custom or default `~/DevDrive/fleet.json`)
/// - Auto-mount behaviour on host connect
/// - Keep-awake per source volume
/// - Reconcile daemon control
struct DevDriveSettingsView: View {

    // MARK: Persisted preferences

    @AppStorage("devDrive.fleetPath")         private var fleetPath = ""
    @AppStorage("devDrive.autoMountEnabled")  private var autoMountEnabled = true
    @AppStorage("devDrive.notifyOnMount")     private var notifyOnMount = true
    @AppStorage("devDrive.notifyOnFail")      private var notifyOnFail = true
    @AppStorage("devDrive.defaultViewMode")   private var defaultViewMode: DevDriveViewMode = .list
    /// Persistence + autoconnect: on app launch, automatically attach all auto-policy
    /// sparseimages whose host volume is currently mounted. Default ON.
    @AppStorage("lfg.autoAttachOnLaunch")     private var autoAttachOnLaunch = true

    // MARK: Transient state

    @State private var registry: FleetRegistry?
    @State private var daemonStatus: String = "Checking…"
    @State private var isTogglingDaemon = false

    // MARK: Body

    var body: some View {
        Form {
            fleetSection
            mountSection
            notificationSection
            daemonSection
            sourceVolumeKeepAwakeSection
        }
        .formStyle(.grouped)
        .onAppear { refreshStatus() }
    }

    // MARK: Fleet

    private var fleetSection: some View {
        Section("Fleet File") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("~/DevDrive/fleet.json", text: $fleetPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Reset") { fleetPath = "" }
                        .controlSize(.small)
                }
                Text("Leave empty to use the default location: ~/DevDrive/fleet.json")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Default View", selection: $defaultViewMode) {
                ForEach(DevDriveViewMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
        }
    }

    // MARK: Mount behaviour

    private var mountSection: some View {
        Section("Auto-Mount") {
            Toggle("Attach sparseimages when host volume connects", isOn: $autoMountEnabled)
            Text("When enabled, LFG watches NSWorkspace for mount events and calls `hdiutil attach` for all auto-policy volumes on the connecting host.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Auto-attach known volumes on launch", isOn: $autoAttachOnLaunch)
            Text("On app launch (including login auto-launch), scan all SourceVolumes in fleet.json and attach auto-policy sparseimages for any host that is already mounted. Recommended for menubar-only sessions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Notifications

    private var notificationSection: some View {
        Section("Notifications") {
            Toggle("Notify when volumes mount successfully", isOn: $notifyOnMount)
            Toggle("Notify on mount failure", isOn: $notifyOnFail)
        }
    }

    // MARK: Daemon

    private var daemonSection: some View {
        Section("Reconcile Daemon") {
            HStack {
                Image(systemName: daemonStatus.contains("Running") ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(daemonStatus.contains("Running") ? Color.green : Color.secondary)
                Text(daemonStatus)
                    .font(.callout)
                Spacer()
                if isTogglingDaemon {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button("Restart") { Task { await restartDaemon() } }
                        .controlSize(.small)
                    Button("Stop") { Task { await stopDaemon() } }
                        .controlSize(.small)
                }
            }
            Text("The reconcile daemon runs as a LaunchAgent and repairs broken symlinks automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Per-source keep-awake

    @ViewBuilder
    private var sourceVolumeKeepAwakeSection: some View {
        let sources = registry?.allSourceVolumes.sorted { $0.name < $1.name } ?? []
        if !sources.isEmpty {
            Section("Source Volume — Keep Awake") {
                ForEach(sources, id: \.name) { source in
                    keepAwakeRow(source: source)
                }
            }
        }
    }

    private func keepAwakeRow(source: SourceVolume) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.body)
                Text(source.mount).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { source.keepAwake },
                set: { newVal in toggleKeepAwake(source: source, value: newVal) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    // MARK: Helpers

    private func resolvedFleetURL() -> URL {
        if !fleetPath.isEmpty {
            return URL(fileURLWithPath: (fleetPath as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
    }

    private func refreshStatus() {
        registry = try? FleetRegistry(url: resolvedFleetURL())
        let laPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.lfg.devdrive-reconcile.plist").path
        let loaded = FileManager.default.fileExists(atPath: laPath)
        daemonStatus = loaded ? "Running (LaunchAgent loaded)" : "Not loaded"
    }

    @MainActor
    private func restartDaemon() async {
        isTogglingDaemon = true
        defer { isTogglingDaemon = false }
        _ = try? await ProcessRunner.shell(
            "launchctl unload ~/Library/LaunchAgents/io.lfg.devdrive-reconcile.plist 2>/dev/null;" +
            "launchctl load ~/Library/LaunchAgents/io.lfg.devdrive-reconcile.plist 2>/dev/null"
        )
        refreshStatus()
    }

    @MainActor
    private func stopDaemon() async {
        isTogglingDaemon = true
        defer { isTogglingDaemon = false }
        _ = try? await ProcessRunner.shell(
            "launchctl unload ~/Library/LaunchAgents/io.lfg.devdrive-reconcile.plist 2>/dev/null"
        )
        daemonStatus = "Not loaded"
    }

    private func toggleKeepAwake(source: SourceVolume, value: Bool) {
        let url = resolvedFleetURL()
        try? FleetEditor.updateSourceVolume(name: source.name, at: url) { host in
            host["keep_awake"] = value
        }
        refreshStatus()
    }
}

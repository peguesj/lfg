import SwiftUI
import LFGKit

/// MenuBar popover providing at-a-glance disk status, per-volume mount indicators,
/// and quick-action buttons for common DevDrive operations.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    @State private var fleetRows: [MenuBarVolumeRow] = []
    @State private var isMountingAll = false
    @State private var isReconciling = false
    @State private var actionMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider()
            diskUsageSection
            Divider()
            moduleStatusSection
            Divider()
            volumeSection
            Divider()
            quickActionsSection
            Divider()
            footerSection
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            appState.updateDiskInfo()
            Task { await loadFleet() }
        }
    }

    // MARK: Sections

    private var headerRow: some View {
        HStack {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.purple)
            Text("LFG — Local File Guardian")
                .font(.headline)
        }
    }

    private var diskUsageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Internal Disk")
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.0f%% used", appState.diskUsagePercent))
                    .font(.caption)
                    .foregroundStyle(appState.diskUsagePercent > 90 ? .red : .secondary)
            }
            ProgressView(value: appState.diskUsagePercent, total: 100)
                .tint(diskTint)
            Text("\(SizeFormatter.format(appState.freeDiskSpace)) free of \(SizeFormatter.format(appState.totalDiskSpace))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var diskTint: Color {
        if appState.diskUsagePercent > 90 { return .red }
        if appState.diskUsagePercent > 80 { return .orange }
        return .blue
    }

    private var moduleStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Modules")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(LFGModule.allCases) { module in
                let status = appState.moduleStatuses[module] ?? ModuleStatus()
                HStack {
                    Image(systemName: module.icon)
                        .foregroundStyle(module.color)
                        .frame(width: 18)
                    Text(module.rawValue)
                        .font(.callout)
                    Spacer()
                    moduleStateIndicator(status.state)
                }
            }
        }
    }

    @ViewBuilder
    private func moduleStateIndicator(_ state: ModuleRunState) -> some View {
        switch state {
        case .idle:
            Text("idle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DevDrive Volumes")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if fleetRows.isEmpty {
                Text("No volumes registered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fleetRows) { row in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(row.isMounted ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(row.id)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.isMounted ? "mounted" : "detached")
                            .font(.caption2)
                            .foregroundStyle(row.isMounted ? .green : .secondary)
                    }
                }
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = actionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await mountAllDevDrives() }
                } label: {
                    Label("Mount All DevDrives", systemImage: "arrow.up.circle")
                        .font(.callout)
                }
                .disabled(isMountingAll || isReconciling)
                .controlSize(.small)

                Spacer()

                Button {
                    Task { await triggerReconcile() }
                } label: {
                    Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                }
                .disabled(isMountingAll || isReconciling)
                .controlSize(.small)
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open LFG") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(.callout)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.red)
        }
    }

    // MARK: Async Actions

    @MainActor
    private func loadFleet() async {
        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
        guard let registry = try? FleetRegistry(url: fleetURL) else { return }

        // Determine mount state via hdiutil
        let mountedPaths: Set<String>
        if let result = try? await ProcessRunner.shell(
            "hdiutil info -plist 2>/dev/null | grep -A1 'mount-point' | grep string | sed 's/.*<string>\\(.*\\)<\\/string>.*/\\1/'"
        ) {
            mountedPaths = Set(
                result.stdout
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        } else {
            mountedPaths = []
        }

        fleetRows = registry.allDrives.sorted(by: { $0.id < $1.id }).map { drive in
            MenuBarVolumeRow(
                id: drive.id,
                mountPath: drive.mount,
                isMounted: mountedPaths.contains(drive.mount)
            )
        }
    }

    @MainActor
    private func mountAllDevDrives() async {
        isMountingAll = true
        actionMessage = "Mounting all volumes…"
        defer { isMountingAll = false }
        _ = try? await ProcessRunner.shell(
            "~/tools/@yj/lfg/lfg devdrive mount-all 2>&1"
        )
        actionMessage = "Mount complete."
        await loadFleet()
        appState.updateDiskInfo()
    }

    @MainActor
    private func triggerReconcile() async {
        isReconciling = true
        actionMessage = "Reconciling…"
        defer { isReconciling = false }
        _ = try? await ProcessRunner.shell(
            "python3 ~/tools/@yj/lfg/devdrive/daemon.py --once 2>&1"
        )
        actionMessage = "Reconcile complete."
        await loadFleet()
    }
}

// MARK: - MenuBarVolumeRow

private struct MenuBarVolumeRow: Identifiable {
    let id: String
    let mountPath: String
    let isMounted: Bool
}

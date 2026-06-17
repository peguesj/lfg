import SwiftUI
import LFGKit

// MARK: - DevDriveOperationsView

/// Operational controls for DevDrive volumes.
///
/// Displays all fleet volumes with per-volume mount/unmount toggles, toolbar
/// batch actions, symlink repair, reconcile trigger, and directory offload.
/// All operations are async and report progress inline — no modal alerts for
/// transient errors.
struct DevDriveOperationsView: View {

    // MARK: State

    @State private var volumes: [VolumeRecord] = []
    @State private var isLoading = false
    @State private var operationError: String? = nil
    @State private var busyVolumeIDs: Set<String> = []
    @State private var globalBusy = false
    @State private var globalMessage: String? = nil
    @State private var showOffloadPicker = false
    @State private var offloadTargetID: String? = nil

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if let err = operationError {
                errorBanner(err)
            }
            if let msg = globalMessage {
                infoBanner(msg)
            }

            if isLoading {
                ProgressView("Loading fleet…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if volumes.isEmpty {
                emptyState
            } else {
                volumeList
            }
        }
        .navigationTitle("DevDrive Operations")
        .toolbar { toolbarItems }
        .task { await refresh() }
        .fileImporter(
            isPresented: $showOffloadPicker,
            allowedContentTypes: [.folder]
        ) { result in
            Task { await handleOffload(result: result) }
        }
    }

    // MARK: Volume List

    private var volumeList: some View {
        List {
            ForEach(volumes, id: \.id) { volume in
                VolumeRowView(
                    volume: volume,
                    isBusy: busyVolumeIDs.contains(volume.id),
                    onMount: { Task { await mountVolume(volume) } },
                    onUnmount: { Task { await unmountVolume(volume) } }
                )
            }
        }
        .listStyle(.inset)
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Volumes Registered")
                .font(.title2.bold())
            Text("Run `lfg devdrive init` in Terminal to initialise the fleet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Refresh") { Task { await refresh() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await mountAll() }
            } label: {
                Label("Mount All", systemImage: "arrow.up.circle.fill")
            }
            .disabled(globalBusy)

            Button {
                Task { await unmountAll() }
            } label: {
                Label("Unmount All", systemImage: "arrow.down.circle.fill")
            }
            .disabled(globalBusy)

            Divider()

            Button {
                Task { await repairSymlinks() }
            } label: {
                Label("Repair Symlinks", systemImage: "link.badge.plus")
            }
            .disabled(globalBusy)

            Button {
                Task { await triggerReconcile() }
            } label: {
                Label("Trigger Reconcile", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(globalBusy)

            Button {
                showOffloadPicker = true
            } label: {
                Label("Offload Directory…", systemImage: "tray.and.arrow.down.fill")
            }
            .disabled(globalBusy || mountedVolumes.isEmpty)

            Divider()

            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading || globalBusy)
        }
    }

    // MARK: Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                operationError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1))
    }

    private func infoBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(message)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.08))
    }

    // MARK: Helpers

    private var mountedVolumes: [VolumeRecord] {
        volumes.filter { $0.status == .mounted }
    }

    // MARK: Async Operations

    @MainActor
    private func refresh() async {
        isLoading = true
        operationError = nil
        defer { isLoading = false }
        do {
            let result = try await ProcessRunner.shell(
                "hdiutil info -plist 2>/dev/null | plutil -convert json -o - -"
            )
            volumes = buildVolumeRecords(hdiutilOutput: result.stdout)
        } catch {
            operationError = "Failed to query volumes: \(error.localizedDescription)"
        }
    }

    /// Builds VolumeRecord array by reading fleet.json and cross-referencing hdiutil output.
    private func buildVolumeRecords(hdiutilOutput: String) -> [VolumeRecord] {
        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
        guard
            let registry = try? FleetRegistry(url: fleetURL)
        else { return [] }

        let attachedPaths = parseAttachedMountPaths(from: hdiutilOutput)

        return registry.allDrives.sorted(by: { $0.id < $1.id }).map { drive in
            let isMounted = attachedPaths.contains(drive.mount)
            return VolumeRecord(
                id: drive.id,
                image: drive.resolvedImagePath,
                mountPath: drive.mount,
                host: drive.host,
                status: isMounted ? .mounted : .detached
            )
        }
    }

    private func parseAttachedMountPaths(from json: String) -> Set<String> {
        guard
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let images = obj["images"] as? [[String: Any]]
        else { return [] }
        var paths: Set<String> = []
        for image in images {
            if let sfs = image["system-entities"] as? [[String: Any]] {
                for sf in sfs {
                    if let mp = sf["mount-point"] as? String { paths.insert(mp) }
                }
            }
        }
        return paths
    }

    @MainActor
    private func mountVolume(_ volume: VolumeRecord) async {
        busyVolumeIDs.insert(volume.id)
        operationError = nil
        defer { busyVolumeIDs.remove(volume.id) }
        do {
            let result = try await ProcessRunner.shell(
                "hdiutil attach \(shellEscape(volume.image)) -mountpoint \(shellEscape(volume.mountPath)) -nobrowse -quiet"
            )
            if !result.succeeded {
                operationError = "Mount failed [\(volume.id)]: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            await refresh()
        } catch {
            operationError = "Mount error [\(volume.id)]: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func unmountVolume(_ volume: VolumeRecord) async {
        busyVolumeIDs.insert(volume.id)
        operationError = nil
        defer { busyVolumeIDs.remove(volume.id) }
        do {
            let result = try await ProcessRunner.shell(
                "hdiutil detach \(shellEscape(volume.mountPath)) -quiet"
            )
            if !result.succeeded {
                operationError = "Unmount failed [\(volume.id)]: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            await refresh()
        } catch {
            operationError = "Unmount error [\(volume.id)]: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func mountAll() async {
        globalBusy = true
        globalMessage = "Mounting all volumes…"
        operationError = nil
        defer { globalBusy = false; globalMessage = nil }
        do {
            let result = try await ProcessRunner.shell(
                "~/tools/@yj/lfg/scripts/devdrive-rsync-mirror.sh mount-all 2>&1 || " +
                "for v in ~/DevDrive/*.sparseimage; do hdiutil attach \"$v\" -nobrowse -quiet; done"
            )
            if !result.succeeded {
                operationError = "Mount All: some volumes may have failed."
            }
            await refresh()
        } catch {
            operationError = "Mount All error: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func unmountAll() async {
        globalBusy = true
        globalMessage = "Unmounting all volumes…"
        operationError = nil
        defer { globalBusy = false; globalMessage = nil }
        let targets = mountedVolumes.map { shellEscape($0.mountPath) }.joined(separator: " ")
        guard !targets.isEmpty else { globalMessage = nil; return }
        do {
            let result = try await ProcessRunner.shell("hdiutil detach \(targets) -quiet")
            if !result.succeeded {
                operationError = "Unmount All: some volumes may have failed."
            }
            await refresh()
        } catch {
            operationError = "Unmount All error: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func repairSymlinks() async {
        globalBusy = true
        globalMessage = "Repairing symlinks…"
        operationError = nil
        defer { globalBusy = false; globalMessage = nil }
        do {
            let script = "~/tools/@yj/lfg/lfg devdrive repair 2>&1"
            let result = try await ProcessRunner.shell(script)
            if result.succeeded {
                globalMessage = "Symlink repair complete."
            } else {
                operationError = "Repair: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        } catch {
            operationError = "Repair error: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func triggerReconcile() async {
        globalBusy = true
        globalMessage = "Running reconcile…"
        operationError = nil
        defer { globalBusy = false; globalMessage = nil }
        do {
            let projectRoot = "~/tools/@yj/lfg"
            let result = try await ProcessRunner.shell(
                "python3 \(projectRoot)/devdrive/daemon.py --once 2>&1"
            )
            if result.succeeded {
                globalMessage = "Reconcile complete."
            } else {
                operationError = "Reconcile: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        } catch {
            operationError = "Reconcile error: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func handleOffload(result: Result<URL, Error>) async {
        switch result {
        case .failure(let err):
            operationError = "Picker error: \(err.localizedDescription)"
            return
        case .success(let url):
            guard let target = offloadTargetID ?? mountedVolumes.first?.mountPath else {
                operationError = "No mounted volume available for offload."
                return
            }
            globalBusy = true
            globalMessage = "Offloading \(url.lastPathComponent)…"
            operationError = nil
            defer { globalBusy = false; globalMessage = nil }
            do {
                let src = shellEscape(url.path)
                let dst = shellEscape(target + "/" + url.lastPathComponent)
                let result = try await ProcessRunner.shell(
                    "mv \(src) \(dst) && ln -s \(dst) \(src)"
                )
                if result.succeeded {
                    globalMessage = "Offloaded \(url.lastPathComponent) to \(target)"
                } else {
                    operationError = "Offload failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            } catch {
                operationError = "Offload error: \(error.localizedDescription)"
            }
        }
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - VolumeRowView

private struct VolumeRowView: View {
    let volume: VolumeRecord
    let isBusy: Bool
    let onMount: () -> Void
    let onUnmount: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(volume.id)
                        .font(.body.bold())
                    Text(volume.host)
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(volume.mountPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status label
            Text(volume.status.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)

            // Action button
            if isBusy {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 60)
            } else {
                Button(volume.status == .mounted ? "Unmount" : "Mount") {
                    volume.status == .mounted ? onUnmount() : onMount()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(volume.status == .hostAbsent)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: isBusy)
        .animation(.easeInOut(duration: 0.2), value: volume.status)
    }

    private var statusColor: Color {
        switch volume.status {
        case .mounted: .green
        case .detached: .orange
        case .hostAbsent: .secondary
        case .error: .red
        }
    }
}

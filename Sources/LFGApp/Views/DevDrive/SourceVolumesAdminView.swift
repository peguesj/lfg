import SwiftUI
import LFGKit

// MARK: - SourceVolumesAdminView

/// Administration panel for all mounted volumes.
///
/// Volumes are grouped into two sections:
/// - **DevDrive-Managed** — `SourceVolume` entries already in `fleet.json`.
/// - **Discovered** — volumes visible to the OS but not yet registered.
///
/// Each Discovered volume carries a `+ Register` button that opens
/// `AddSourceVolumeSheet`, which appends an entry to `fleet.json external_hosts[]`.
struct SourceVolumesAdminView: View {

    // MARK: State

    @State private var mounted: [MountedVolume] = []
    @State private var registry: FleetRegistry?
    @State private var showRegisterSheet = false
    @State private var registerTarget: MountedVolume?
    @State private var isLoading = true
    @State private var successBanner: String?

    // MARK: Body

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Scanning volumes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                volumeContent
            }
        }
        .navigationTitle("Source Volumes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { refresh() }
        .sheet(item: $registerTarget) { vol in
            AddSourceVolumeSheet(volume: vol) { refresh() }
        }
    }

    // MARK: Volume content

    private var volumeContent: some View {
        VStack(spacing: 0) {
            if let banner = successBanner {
                successBannerView(banner)
            }
            List {
                managedSection
                discoveredSection
            }
            .listStyle(.inset)
        }
    }

    // MARK: Managed section

    private var managedSection: some View {
        let managed = managedVolumes
        return Section {
            if managed.isEmpty {
                Text("No registered source volumes in fleet.json")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(managed, id: \.mounted.id) { pair in
                    ManagedVolumeRow(mounted: pair.mounted, source: pair.source, registry: registry)
                }
            }
        } header: {
            Label("DevDrive-Managed", systemImage: "externaldrive.fill.badge.checkmark")
                .textCase(nil)
                .font(.subheadline.bold())
        }
    }

    // MARK: Discovered section

    private var discoveredSection: some View {
        let discovered = discoveredVolumes
        return Section {
            if discovered.isEmpty {
                Text("All mounted volumes are registered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(discovered) { vol in
                    DiscoveredVolumeRow(volume: vol) {
                        registerTarget = vol
                    }
                }
            }
        } header: {
            Label("Discovered (unregistered)", systemImage: "externaldrive.badge.plus")
                .textCase(nil)
                .font(.subheadline.bold())
        }
    }

    // MARK: Helpers

    private struct ManagedPair {
        let mounted: MountedVolume
        let source: SourceVolume
    }

    private var managedMountPoints: Set<String> {
        Set(registry?.allSourceVolumes.map(\.mount) ?? [])
    }

    private var managedVolumes: [ManagedPair] {
        guard let registry else { return [] }
        return registry.allSourceVolumes.compactMap { source in
            guard let mv = mounted.first(where: { $0.mountPoint == source.mount }) else { return nil }
            return ManagedPair(mounted: mv, source: source)
        }
        .sorted { $0.source.name < $1.source.name }
    }

    private var discoveredVolumes: [MountedVolume] {
        let managed = managedMountPoints
        // Exclude macOS root and DevDrive sparseimage mount points — focus on physical hosts.
        let sparsepoints = Set(registry?.allVolumeBackends.map(\.mount) ?? [])
        return mounted.filter { vol in
            !managed.contains(vol.mountPoint) &&
            !sparsepoints.contains(vol.mountPoint) &&
            vol.mountPoint != "/" &&
            vol.totalBytes > 0
        }
    }

    // MARK: Banner

    private func successBannerView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.callout)
            Spacer()
            Button { successBanner = nil } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.green.opacity(0.08))
    }

    // MARK: Data loading

    private func refresh() {
        isLoading = true
        mounted = DiskScanner.scan()
        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
        registry = try? FleetRegistry(url: fleetURL)
        isLoading = false
    }
}

// MARK: - ManagedVolumeRow

private struct ManagedVolumeRow: View {
    let mounted: MountedVolume
    let source: SourceVolume
    let registry: FleetRegistry?

    private var backendCount: Int {
        registry?.volumeBackends(forHost: source.name).count ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name).font(.body.bold())
                    if backendCount > 0 {
                        Text("\(backendCount) vols")
                            .font(.caption)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    if source.keepAwake {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(source.mount).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                capacityBar
                Text(String(format: "%.0f GB free / %.0f GB", mounted.freeGB, mounted.totalGB))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var capacityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(capacityColor)
                    .frame(width: geo.size.width * mounted.usageRatio)
            }
        }
        .frame(width: 100, height: 6)
    }

    private var capacityColor: Color {
        switch mounted.usageRatio {
        case ..<0.7:  .green
        case ..<0.85: .orange
        default:      .red
        }
    }
}

// MARK: - DiscoveredVolumeRow

private struct DiscoveredVolumeRow: View {
    let volume: MountedVolume
    let onRegister: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name).font(.body)
                HStack(spacing: 4) {
                    Text(volume.mountPoint).font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Text(volume.fileSystemType).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if volume.totalBytes > 0 {
                Text(String(format: "%.0f GB", volume.totalGB))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("+ Register") { onRegister() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AddSourceVolumeSheet

/// Modal form to register a discovered volume as a DevDrive source.
///
/// Appends a new entry to `fleet.json external_hosts[]` atomically.
struct AddSourceVolumeSheet: View {

    let volume: MountedVolume
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameField: String = ""
    @State private var roleField = "external_host"
    @State private var keepAwake = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(volume: MountedVolume, onComplete: @escaping () -> Void) {
        self.volume = volume
        self.onComplete = onComplete
        _nameField = State(initialValue: volume.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Volume Details") {
                    LabeledContent("Mount Point", value: volume.mountPoint)
                    LabeledContent("File System", value: volume.fileSystemType)
                    LabeledContent("Total Space", value: String(format: "%.1f GB", volume.totalGB))
                }

                Section("Fleet Registration") {
                    TextField("Name (used as fleet key)", text: $nameField)
                        .textFieldStyle(.roundedBorder)
                    TextField("Role", text: $roleField)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Keep Awake (prevent spin-down)", isOn: $keepAwake)
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Register Source Volume")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Register") {
                        Task { await register() }
                    }
                    .disabled(nameField.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    @MainActor
    private func register() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")

        do {
            var raw = try JSONSerialization.jsonObject(
                with: try Data(contentsOf: fleetURL)
            ) as? [String: Any] ?? [:]

            var hosts = raw["external_hosts"] as? [[String: Any]] ?? []

            let trimmedName = nameField.trimmingCharacters(in: .whitespaces)
            guard !hosts.contains(where: { ($0["name"] as? String) == trimmedName }) else {
                errorMessage = "A source volume named '\(trimmedName)' already exists."
                return
            }

            hosts.append([
                "name":         trimmedName,
                "mount":        volume.mountPoint,
                "role":         roleField.trimmingCharacters(in: .whitespaces),
                "available_gb": Int(volume.freeGB),
                "status":       "active",
                "keep_awake":   keepAwake
            ])
            raw["external_hosts"] = hosts

            let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fleetURL, options: .atomic)

            onComplete()
            dismiss()
        } catch {
            errorMessage = "Could not update fleet.json: \(error.localizedDescription)"
        }
    }
}

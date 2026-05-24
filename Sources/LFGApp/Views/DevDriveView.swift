import SwiftUI
import LFGKit

// MARK: - DevDriveView

/// Top-level DevDrive view — a CloudMounter-inspired three-tier collapsible list.
///
/// Hierarchy:
/// ```
/// DevDriveView
/// └── List
///     ├── Section: "YJ_MORE"  (external SourceVolume)
///     │   ├── VolumeBackendCard: 900HOOKS  [capacity bar] [status dot] [▶]
///     │   │   └── OffloadRuleRow: ~/.npm-cache → /Volumes/…  [●] [Restore]
///     │   └── VolumeBackendCard: 901DEVLIB
///     │       ├── OffloadRuleRow: ~/.asdf → …
///     │       └── OffloadRuleRow: ~/.vscode → …
///     └── Section: "Internal"
///         ├── VolumeBackendCard: 902APMDR
///         └── VolumeBackendCard: 903LUME
/// ```
///
/// The fleet is loaded lazily via `.task {}` from `~/DevDrive/fleet.json`.
/// Any `VolumeBackend` whose `host` does not match a known `SourceVolume` falls
/// into the synthetic "Internal" section.
struct DevDriveView: View {

    // MARK: State

    @State private var registry: FleetRegistry?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var showSourceVolumes = false
    @State private var showOffloadRules = false
    @State private var showCapacityDashboard = false

    /// Persisted display mode — survives app restarts.
    @AppStorage("devDriveViewMode") private var viewMode: DevDriveViewMode = .list

    // MARK: Body

    var body: some View {
        Group {
            if isLoading {
                loadingState
            } else if let error = loadError {
                errorState(error)
            } else if let registry {
                currentView(registry: registry)
            } else {
                emptyState
            }
        }
        .navigationTitle("DevDrive")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSourceVolumes = true
                } label: {
                    Label("Source Volumes", systemImage: "externaldrive.badge.checkmark")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showOffloadRules = true
                } label: {
                    Label("Offload Rules", systemImage: "link.badge.plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCapacityDashboard = true
                } label: {
                    Label("Capacity", systemImage: "chart.bar.fill")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Picker("View", selection: $viewMode) {
                    ForEach(DevDriveViewMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Switch display mode")
            }
        }
        .sheet(isPresented: $showSourceVolumes) {
            NavigationStack {
                SourceVolumesAdminView()
            }
            .frame(minWidth: 640, minHeight: 480)
        }
        .sheet(isPresented: $showOffloadRules) {
            OffloadRuleManagerSheet()
        }
        .sheet(isPresented: $showCapacityDashboard) {
            NavigationStack {
                CapacityDashboardView()
            }
            .frame(minWidth: 680, minHeight: 500)
        }
        .task { await reload() }
    }

    // MARK: View dispatch

    /// Routes to the active display mode's view.
    @ViewBuilder
    private func currentView(registry: FleetRegistry) -> some View {
        switch viewMode {
        case .list:
            fleetList(registry: registry)
        case .card:
            VolumeCardGridView(registry: registry)
        case .graph:
            VolumeGraphView(registry: registry)
        }
    }

    // MARK: Fleet list

    private func fleetList(registry: FleetRegistry) -> some View {
        let sections = buildSections(registry: registry)
        return List {
            ForEach(sections, id: \.title) { section in
                SourceVolumeSection(
                    title: section.title,
                    isMounted: section.isMounted,
                    backends: section.backends
                )
            }
        }
        .listStyle(.inset)
    }

    // MARK: Placeholder states

    private var loadingState: some View {
        ProgressView("Loading fleet…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Could not load fleet.json")
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Volumes Registered")
                .font(.title3.bold())
            Text("Run `lfg devdrive init` in Terminal to initialise the fleet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Data loading

    @MainActor
    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let fleetURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")

        do {
            registry = try FleetRegistry(url: fleetURL)
        } catch {
            loadError = error.localizedDescription
            registry = nil
        }
    }

    // MARK: Section model

    private struct SectionModel {
        let title: String
        let isMounted: Bool
        let backends: [VolumeBackend]
    }

    /// Partitions all `VolumeBackend` entries into per-`SourceVolume` sections.
    ///
    /// - Backends whose `host` matches a known `SourceVolume` are grouped under
    ///   that source, with `isMounted` reflecting `SourceVolume.isMounted`.
    /// - Backends whose `host` does not match any known `SourceVolume` are
    ///   placed in a synthetic **"Internal"** section.
    private func buildSections(registry: FleetRegistry) -> [SectionModel] {
        var sections: [SectionModel] = []
        let knownHosts: Set<String> = Set(registry.allSourceVolumes.map(\.name))

        // One section per known SourceVolume, sorted by name for stability.
        let sortedSources = registry.allSourceVolumes.sorted { $0.name < $1.name }
        for source in sortedSources {
            let backends = registry.volumeBackends(forHost: source.name)
            guard !backends.isEmpty else { continue }
            sections.append(SectionModel(
                title: source.name,
                isMounted: source.isMounted,
                backends: backends
            ))
        }

        // Collect any backends not assigned to a known external host.
        let internalBackends = registry.allVolumeBackends.filter { !knownHosts.contains($0.host) }
        if !internalBackends.isEmpty {
            sections.append(SectionModel(
                title: "Internal",
                isMounted: true,   // internal volumes are always considered "present"
                backends: internalBackends
            ))
        }

        return sections
    }
}

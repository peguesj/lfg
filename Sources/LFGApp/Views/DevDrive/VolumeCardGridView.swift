import SwiftUI
import LFGKit

// MARK: - VolumeCardGridView

/// A card grid presenting every `VolumeBackend` in the fleet, grouped by source volume.
///
/// Layout:
/// ```
/// ScrollView
/// └── VStack (sections)
///     ├── Text("YJ_MORE")  ← section header
///     ├── LazyVGrid
///     │   ├── VolumeCard: 901DEVLIB
///     │   └── VolumeCard: 904MEMVT
///     ├── Text("Internal")
///     └── LazyVGrid
///         ├── VolumeCard: 902APMDR
///         └── VolumeCard: 903LUME
/// ```
///
/// The grid uses adaptive columns with a minimum width of 220 pt so the layout
/// reflows naturally when the window is resized.
struct VolumeCardGridView: View {

    // MARK: Input

    let registry: FleetRegistry

    // MARK: Layout constants

    private let gridColumns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let sections = buildSections(registry: registry)
                ForEach(sections, id: \.title) { section in
                    sectionBlock(section)
                }
            }
            .padding(16)
        }
    }

    // MARK: Section block

    private func sectionBlock(_ section: SectionModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(section.isMounted ? .primary : .secondary)

            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(section.backends, id: \.id) { backend in
                    VolumeCard(backend: backend, hostIsMounted: section.isMounted)
                }
            }
        }
    }

    // MARK: Section model

    private struct SectionModel {
        let title: String
        let isMounted: Bool
        let backends: [VolumeBackend]
    }

    /// Partitions all `VolumeBackend` entries into per-`SourceVolume` sections,
    /// mirroring the logic in `DevDriveView.buildSections(registry:)`.
    private func buildSections(registry: FleetRegistry) -> [SectionModel] {
        var sections: [SectionModel] = []
        let knownHosts: Set<String> = Set(registry.allSourceVolumes.map(\.name))

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

        let internalBackends = registry.allVolumeBackends.filter { !knownHosts.contains($0.host) }
        if !internalBackends.isEmpty {
            sections.append(SectionModel(
                title: "Internal",
                isMounted: true,
                backends: internalBackends
            ))
        }

        return sections
    }
}

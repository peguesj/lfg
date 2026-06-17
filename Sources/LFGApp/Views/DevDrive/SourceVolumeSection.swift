import SwiftUI
import LFGKit

// MARK: - SourceVolumeSection

/// A `List` section that groups `VolumeBackendCard` items under a single
/// `SourceVolume` header.
///
/// The section header shows the source volume's display name and a mounted /
/// ejected badge so the user can see at a glance whether the physical drive is
/// available.
///
/// Usage:
/// ```swift
/// SourceVolumeSection(
///     title: "YJ_MORE",
///     isMounted: true,
///     backends: registry.volumeBackends(forHost: "YJ_MORE")
/// )
/// ```
struct SourceVolumeSection: View {

    // MARK: Input

    /// Display name for the section header (typically the `SourceVolume.name`).
    let title: String

    /// Whether the physical host volume is currently mounted.
    let isMounted: Bool

    /// The `VolumeBackend` entries to display within this section.
    let backends: [VolumeBackend]

    // MARK: Body

    var body: some View {
        Section {
            ForEach(sortedBackends, id: \.id) { backend in
                VolumeBackendCard(backend: backend)
            }
        } header: {
            sectionHeader
        }
    }

    // MARK: Section header

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: isMounted ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(isMounted ? .primary : .secondary)

            Text(title)
                .font(.headline)

            Spacer(minLength: 0)

            // Mounted / not-mounted badge
            Text(isMounted ? "Mounted" : "Not Mounted")
                .font(.caption.weight(.medium))
                .foregroundStyle(isMounted ? .green : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    (isMounted ? Color.green : Color.secondary).opacity(0.12),
                    in: Capsule()
                )
        }
        .padding(.vertical, 2)
    }

    // MARK: Helpers

    /// Backends sorted alphabetically by `id` for a stable display order.
    private var sortedBackends: [VolumeBackend] {
        backends.sorted { $0.id < $1.id }
    }
}

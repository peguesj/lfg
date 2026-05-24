import SwiftUI
import LFGKit

// MARK: - CapacityInfo

/// Filesystem capacity figures read from `FileManager` for a mounted volume.
private struct CapacityInfo {
    let usedBytes: Int64
    let totalBytes: Int64

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    var displayString: String {
        "\(Self.gbString(usedBytes)) used / \(Self.gbString(totalBytes)) total"
    }

    private static func gbString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }
}

// MARK: - VolumeBackendCard

/// A collapsible card for a single `VolumeBackend`.
///
/// Header row:
/// ```
/// ▶  901DEVLIB          [status dot]
///    Xcode DerivedData…  [XX GB used / YY GB total bar]
/// ```
///
/// When expanded, each `OffloadRule` renders as an `OffloadRuleRow` beneath the card.
struct VolumeBackendCard: View {

    // MARK: Input

    let backend: VolumeBackend

    // MARK: State

    @State private var expanded = false
    @State private var capacityInfo: CapacityInfo?
    @State private var status: VolumeStatus = .unmounted
    @State private var showRelocation = false
    @State private var showSettings = false

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                .contextMenu {
                    Button("Settings…") { showSettings = true }
                    Button("Relocate to External Drive…") { showRelocation = true }
                }

            if expanded {
                rulesSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task { await loadCapacityAndStatus() }
        .sheet(isPresented: $showRelocation) {
            DriveRelocationSheet(backend: backend)
        }
        .sheet(isPresented: $showSettings) {
            VolumeSettingsSheet(backend: backend) { Task { await loadCapacityAndStatus() } }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            // Expand/collapse chevron
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 3) {
                // Volume id + status dot
                HStack(spacing: 6) {
                    Text(backend.id)
                        .font(.body.bold())
                        .lineLimit(1)
                    VolumeStatusDot(status: status)
                }

                // Purpose subtitle
                if let purpose = backend.purpose {
                    Text(purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Capacity bar
                capacityRow
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: Capacity bar

    @ViewBuilder
    private var capacityRow: some View {
        if let info = capacityInfo {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: info.usedFraction, total: 1.0)
                    .tint(info.usedFraction > 0.9 ? .red : .accentColor)
                    .frame(maxWidth: 220)

                Text(info.displayString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(FileManager.default.fileExists(atPath: backend.mount) ? "Reading…" : "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rules section

    @ViewBuilder
    private var rulesSection: some View {
        let rules = backend.offloadRules
        if rules.isEmpty {
            Text("No offload rules")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 24)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rules, id: \.source) { rule in
                    OffloadRuleRow(rule: rule)
                }
            }
            .padding(.leading, 20)
            .padding(.vertical, 6)
        }
    }

    // MARK: Async data load

    @MainActor
    private func loadCapacityAndStatus() async {
        // Derive the four-state status synchronously (FileManager calls are fast).
        status = VolumeStatus.derive(from: backend)

        guard FileManager.default.fileExists(atPath: backend.mount) else { return }

        // Read filesystem attributes off the main actor — they're a lightweight
        // stat(2) call and complete in microseconds.
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: backend.mount),
              let totalBytes = attrs[.systemSize] as? Int64,
              let freeBytes  = attrs[.systemFreeSize] as? Int64
        else { return }

        capacityInfo = CapacityInfo(
            usedBytes: max(0, totalBytes - freeBytes),
            totalBytes: totalBytes
        )
    }
}

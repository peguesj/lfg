import SwiftUI
import LFGKit

// MARK: - VolumeCard

/// A card view representing a single `VolumeBackend`.
///
/// Displays status dot, volume ID, host badge, purpose, an async capacity ring,
/// rule count, and tier chip. Tapping the card opens ``VolumeDetailSheet``.
///
/// Layout (top-to-bottom):
/// ```
/// ┌────────────────────────────────────┐
/// │  ● 901DEVLIB              [badge]  │
/// │  Xcode DerivedData + CoreSimulator │
/// │                                    │
/// │  [capacity ring]  XX.X GB / YY GB  │
/// │                                    │
/// │  ⊕ 7 rules          tier: cold    │
/// └────────────────────────────────────┘
/// ```
struct VolumeCard: View {

    // MARK: Input

    let backend: VolumeBackend

    /// Whether the host source volume is currently mounted (used for badge tint).
    let hostIsMounted: Bool

    // MARK: State

    @State private var isDetailPresented = false
    @State private var capacityBytes: (used: Double, total: Double)?

    // MARK: Body

    var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isDetailPresented) {
            VolumeDetailSheet(backend: backend)
        }
        .task {
            await loadCapacity()
        }
    }

    // MARK: Card content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row 1: status dot + id + host badge
            HStack(alignment: .center, spacing: 6) {
                VolumeStatusDot(status: VolumeStatus.derive(from: backend))
                Text(backend.id)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                hostBadge
            }

            // Row 2: purpose
            Text(backend.purpose ?? "No description")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 4)

            Spacer(minLength: 8)

            // Row 3: capacity ring + label
            capacityRow
                .frame(maxWidth: .infinity)

            Spacer(minLength: 8)

            // Row 4: rule count + tier chip
            HStack(alignment: .center) {
                ruleCountLabel
                Spacer()
                tierChip
            }
        }
        .padding(12)
        .frame(height: 180)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        )
    }

    // MARK: Host badge

    private var hostBadge: some View {
        Text(String(backend.host.prefix(12)))
            .font(.caption2.weight(.medium))
            .foregroundStyle(hostIsMounted ? Color.green : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(hostIsMounted ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
            )
    }

    // MARK: Capacity ring

    private var capacityRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                    .frame(width: 36, height: 36)

                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
            }

            Text(capacityLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var usedFraction: CGFloat {
        guard let cap = capacityBytes, cap.total > 0 else { return 0 }
        return CGFloat(min(cap.used / cap.total, 1.0))
    }

    private var ringColor: Color {
        let fraction = usedFraction
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return .green
    }

    private var capacityLabel: String {
        guard let cap = capacityBytes else {
            return FileManager.default.fileExists(atPath: backend.mount) ? "Loading…" : "Unmounted"
        }
        let usedGB = cap.used / 1_073_741_824
        let totalGB = cap.total / 1_073_741_824
        return String(format: "%.1f GB / %.1f GB", usedGB, totalGB)
    }

    // MARK: Rule count

    private var ruleCountLabel: some View {
        Label(
            "\(backend.offloadRules.count) rule\(backend.offloadRules.count == 1 ? "" : "s")",
            systemImage: "link"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Tier chip

    private var tierChip: some View {
        Text(backend.tier ?? "—")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
            )
    }

    // MARK: Async capacity load

    private func loadCapacity() async {
        guard FileManager.default.fileExists(atPath: backend.mount) else { return }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: backend.mount),
              let freeBytes = attrs[.systemFreeSize] as? NSNumber,
              let totalBytes = attrs[.systemSize] as? NSNumber
        else { return }
        let total = totalBytes.doubleValue
        let free = freeBytes.doubleValue
        capacityBytes = (used: total - free, total: total)
    }
}

// MARK: - VolumeDetailSheet

/// A sheet presenting all properties of a ``VolumeBackend`` in read-only form fields.
struct VolumeDetailSheet: View {

    // MARK: Input

    let backend: VolumeBackend

    // MARK: Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                storageSection
                offloadRulesSection
            }
            .formStyle(.grouped)
            .navigationTitle(backend.id)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 480)
    }

    // MARK: Sections

    private var identitySection: some View {
        Section("Identity") {
            LabeledContent("ID", value: backend.id)
            LabeledContent("Host", value: backend.host)
            LabeledContent("Tier", value: backend.tier ?? "—")
            LabeledContent("Purpose", value: backend.purpose ?? "—")
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Image Path", value: backend.resolvedImagePath)
            LabeledContent("Mount Path", value: backend.mount)
            LabeledContent("Reconnect Policy", value: backend.reconnectPolicy ?? "manual")
        }
    }

    private var offloadRulesSection: some View {
        Section("Offload Rules") {
            if backend.offloadRules.isEmpty {
                Text("No rules configured")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backend.offloadRules, id: \.source) { rule in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(rule.isHealthy ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(rule.source)
                            .font(.callout)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(rule.target)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

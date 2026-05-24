import SwiftUI
import LFGKit

// MARK: - DriveRelocationSheet

/// Step-based wizard for moving a sparseimage to a different host volume.
///
/// Step 1 — Select destination: picker of available mounted source volumes.
/// Step 2 — Review: shows source path, destination, size estimate, and warnings.
/// Step 3 — Progress: live phase + status feedback during relocation.
/// Step 4 — Done / Error: summary.
struct DriveRelocationSheet: View {

    // MARK: Input

    let backend: VolumeBackend

    @Environment(\.dismiss) private var dismiss

    // MARK: State

    @StateObject private var coordinator = RelocationCoordinator()

    @State private var step: WizardStep = .selectDestination
    @State private var availableHosts: [MountedVolume] = []
    @State private var selectedHost: MountedVolume?

    private enum WizardStep { case selectDestination, review, relocating, done }

    private var fleetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .selectDestination: destinationStep
                case .review:            reviewStep
                case .relocating:        progressStep
                case .done:              doneStep
                }
            }
            .navigationTitle("Relocate \(backend.id)")
            .toolbar { toolbarItems }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { loadHosts() }
    }

    // MARK: Step 1 — Select destination

    private var destinationStep: some View {
        Form {
            Section("Source") {
                LabeledContent("Volume", value: backend.id)
                LabeledContent("Current image", value: backend.resolvedImagePath)
                LabeledContent("Host", value: backend.host)
            }

            Section("Destination Host") {
                destinationPickerContent
            }

            Section {
                Text("The sparseimage will be copied to `<destination>/DevDrive/` before the original is removed. The mount point stays unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Step 2 — Review

    private var reviewStep: some View {
        Form {
            Section("Relocation Plan") {
                LabeledContent("Volume", value: backend.id)
                LabeledContent("From", value: backend.resolvedImagePath)
                if let host = selectedHost {
                    LabeledContent("To", value: destinationDir(for: host))
                    if host.freeGB < 2 {
                        warningRow("Destination has less than 2 GB free.")
                    }
                }
            }

            Section("Steps") {
                ForEach(["Detach if mounted", "rsync copy (sparse-preserving)", "Update fleet.json", "Re-attach at original mount point", "Remove original"], id: \.self) { step in
                    Label(step, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            Section {
                Text("This operation is safe to cancel **before** the copy starts. After copying begins, cancellation is not supported — wait for completion.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Step 3 — Progress

    private var progressStep: some View {
        VStack(spacing: 20) {
            Spacer()

            phaseIcon
                .font(.system(size: 48))

            Text(phaseSummary)
                .font(.title3.bold())

            Text(coordinator.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if case .copying(let p) = coordinator.phase {
                ProgressView(value: p)
                    .frame(maxWidth: 320)
            } else if coordinator.phase != .complete && coordinator.phase != .failed("") {
                ProgressView()
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: coordinator.phase) { _, new in
            if new == .complete { step = .done }
            if case .failed = new { step = .done }
        }
    }

    // MARK: Step 4 — Done / Error

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()

            if case .failed(let msg) = coordinator.phase {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 48)).foregroundStyle(.red)
                Text("Relocation Failed").font(.title2.bold())
                Text(msg).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Try Again") {
                    coordinator.reset()
                    step = .selectDestination
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(.green)
                Text("Relocation Complete").font(.title2.bold())
                Text("\(backend.id) is now hosted on \(selectedHost?.name ?? "new location").")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(step == .relocating)
        }
        ToolbarItem(placement: .confirmationAction) {
            switch step {
            case .selectDestination:
                Button("Next") { step = .review }
                    .disabled(selectedHost == nil)
            case .review:
                Button("Relocate") { startRelocation() }
                    .buttonStyle(.borderedProminent)
            case .relocating, .done:
                EmptyView()
            }
        }
    }

    // MARK: Extracted pickers

    @ViewBuilder
    private var destinationPickerContent: some View {
        if availableHosts.isEmpty {
            Text("No eligible external volumes found.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Move to", selection: $selectedHost) {
                Text("Select…").tag(Optional<MountedVolume>.none)
                ForEach(availableHosts) { vol in
                    Text("\(vol.name)  (\(String(format: "%.0f GB free", vol.freeGB)))")
                        .tag(Optional(vol))
                }
            }
        }
    }

    // MARK: Helpers

    private func loadHosts() {
        let all = DiskScanner.scan()
        let currentHost = backend.host
        // Only offer volumes that are NOT the current host and have adequate space.
        availableHosts = all.filter { $0.name != currentHost && $0.freeGB > 1 }
    }

    private func destinationDir(for host: MountedVolume) -> String {
        host.mountPoint + "/DevDrive"
    }

    private func startRelocation() {
        guard let host = selectedHost else { return }
        step = .relocating
        let destDir = destinationDir(for: host)
        let url = fleetURL
        Task {
            await coordinator.relocate(backend: backend, destinationDirectory: destDir, fleetURL: url)
        }
    }

    private func warningRow(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange).font(.callout)
    }

    private var phaseIcon: some View {
        Group {
            switch coordinator.phase {
            case .copying:    Image(systemName: "arrow.right.doc.on.clipboard")
            case .complete:   Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:     Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            default:          Image(systemName: "gearshape.2.fill").foregroundStyle(.blue)
            }
        }
    }

    private var phaseSummary: String {
        switch coordinator.phase {
        case .idle:              return "Ready"
        case .preflight:         return "Checking space…"
        case .detaching:         return "Detaching volume…"
        case .copying(let p):    return String(format: "Copying  %.0f%%", p * 100)
        case .updatingFleet:     return "Updating fleet.json…"
        case .reattaching:       return "Re-attaching…"
        case .cleaningUp:        return "Cleaning up…"
        case .complete:          return "Done"
        case .failed:            return "Failed"
        }
    }
}

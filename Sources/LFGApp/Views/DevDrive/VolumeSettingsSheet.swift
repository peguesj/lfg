import SwiftUI
import LFGKit

// MARK: - VolumeSettingsSheet

/// Inline settings editor for a `VolumeBackend` entry in fleet.json.
///
/// Editable fields: purpose, tier, reconnect policy, and the raw symlinks list.
/// Changes are committed atomically via `FleetEditor.updateBackend`.
struct VolumeSettingsSheet: View {

    // MARK: Input

    let backend: VolumeBackend
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    // MARK: Editable state

    @State private var purpose: String
    @State private var tier: String
    @State private var reconnectPolicy: String
    @State private var symlinks: [String]
    @State private var newSymlinkText = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    // MARK: Init

    init(backend: VolumeBackend, onSave: @escaping () -> Void = {}) {
        self.backend = backend
        self.onSave  = onSave
        _purpose          = State(initialValue: backend.purpose ?? "")
        _tier             = State(initialValue: backend.tier ?? "cold")
        _reconnectPolicy  = State(initialValue: backend.reconnectPolicy ?? "auto")
        _symlinks         = State(initialValue: backend.rawSymlinks)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                storageSection
                offloadRulesSection
                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("\(backend.id) Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 460)
    }

    // MARK: Identity section

    private var identitySection: some View {
        Section("Identity") {
            LabeledContent("ID", value: backend.id)
            LabeledContent("Mount Point", value: backend.mount)
            LabeledContent("Image Path", value: backend.resolvedImagePath)
            LabeledContent("Host", value: backend.host)

            HStack {
                Text("Purpose")
                Spacer()
                TextField("Purpose description", text: $purpose)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
        }
    }

    // MARK: Storage section

    private var storageSection: some View {
        Section("Storage") {
            Picker("Tier", selection: $tier) {
                ForEach(["hot", "warm", "cold", "always_internal", "archival"], id: \.self) { t in
                    Text(t).tag(t)
                }
            }

            Picker("Reconnect Policy", selection: $reconnectPolicy) {
                Text("auto — attach when host mounts").tag("auto")
                Text("manual — attach on demand").tag("manual")
                Text("none — never auto-attach").tag("none")
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: Offload rules section

    private var offloadRulesSection: some View {
        Section {
            ForEach(symlinks.indices, id: \.self) { idx in
                HStack {
                    Text(symlinks[idx])
                        .font(.callout.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Button {
                        symlinks.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("~/.tool-cache → /Volumes/VOL/tool-cache", text: $newSymlinkText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button {
                    let trimmed = newSymlinkText.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    symlinks.append(trimmed)
                    newSymlinkText = ""
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newSymlinkText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Offload Rules (symlinks)")
        } footer: {
            Text("Format: `~/.source → /Volumes/VOLID/dest`  (use → U+2192)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Save

    @MainActor
    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")

        let purposeVal  = purpose.trimmingCharacters(in: .whitespaces)
        let tierVal      = tier
        let policyVal    = reconnectPolicy
        let symsVal      = symlinks

        do {
            try FleetEditor.updateBackend(id: backend.id, at: fleetURL) { drive in
                drive["purpose"]           = purposeVal.isEmpty ? nil : purposeVal
                drive["tier"]              = tierVal
                drive["reconnect_policy"]  = policyVal
                drive["symlinks"]          = symsVal
            }
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

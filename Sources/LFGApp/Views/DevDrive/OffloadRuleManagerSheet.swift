import SwiftUI
import LFGKit

// MARK: - OffloadRuleManagerSheet

/// Full-screen manager for all offload rules (symlinks) across the entire fleet.
///
/// Groups rules by `VolumeBackend` and shows per-rule health indicators.
/// Provides Restore (re-create symlink), Add, and Remove actions.
struct OffloadRuleManagerSheet: View {

    // MARK: State

    @State private var registry: FleetRegistry?
    @State private var isLoading = true
    @State private var busyRules: Set<String> = []
    @State private var errorBanners: [String] = []
    @State private var showAddSheet = false
    @State private var addTargetBackendID: String?

    @Environment(\.dismiss) private var dismiss

    private var fleetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading fleet…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ruleContent
                }
            }
            .navigationTitle("Offload Rules")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { reload() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .task { reload() }
        .sheet(isPresented: $showAddSheet) {
            if let id = addTargetBackendID,
               let backend = registry?.allVolumeBackends.first(where: { $0.id == id }) {
                AddOffloadRuleSheet(backend: backend) { reload() }
            }
        }
    }

    // MARK: Rule content

    private var ruleContent: some View {
        VStack(spacing: 0) {
            errorList
            List {
                ForEach(sortedBackends, id: \.id) { backend in
                    Section {
                        backendRuleRows(backend: backend)
                        addRuleButton(for: backend)
                    } header: {
                        backendSectionHeader(backend)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Per-backend rows

    @ViewBuilder
    private func backendRuleRows(backend: VolumeBackend) -> some View {
        let rules = backend.offloadRules
        if rules.isEmpty {
            Text("No offload rules — add one below.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(rules, id: \.source) { rule in
                ruleRow(rule: rule, backend: backend)
            }
        }
    }

    private func ruleRow(rule: OffloadRule, backend: VolumeBackend) -> some View {
        let key = "\(backend.id):\(rule.source)"
        let busy = busyRules.contains(key)
        return HStack(spacing: 10) {
            Circle()
                .fill(rule.isHealthy ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.source).font(.callout.monospaced()).lineLimit(1)
                Text("→ \(rule.target)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if busy {
                ProgressView().scaleEffect(0.7)
            } else if !rule.isHealthy {
                Button("Restore") { Task { await restore(rule: rule, backend: backend) } }
                    .controlSize(.small).buttonStyle(.bordered)
            } else {
                Text("Healthy").font(.caption).foregroundStyle(.green)
            }

            Button { Task { await removeRule(rule: rule, backend: backend) } } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(.vertical, 3)
    }

    private func addRuleButton(for backend: VolumeBackend) -> some View {
        Button {
            addTargetBackendID = backend.id
            showAddSheet = true
        } label: {
            Label("Add Rule to \(backend.id)", systemImage: "plus.circle")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    private func backendSectionHeader(_ backend: VolumeBackend) -> some View {
        HStack {
            Text(backend.id).font(.subheadline.bold())
            Spacer()
            let total = backend.offloadRules.count
            let healthy = backend.offloadRules.filter(\.isHealthy).count
            Text("\(healthy)/\(total) healthy")
                .font(.caption)
                .foregroundStyle(healthy == total ? Color.green : Color.orange)
        }
        .textCase(nil)
    }

    // MARK: Error list

    @ViewBuilder
    private var errorList: some View {
        if !errorBanners.isEmpty {
            VStack(spacing: 0) {
                ForEach(errorBanners, id: \.self) { msg in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(msg).font(.callout)
                        Spacer()
                        Button { errorBanners.removeAll { $0 == msg } } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                    .background(.red.opacity(0.08))
                }
            }
        }
    }

    // MARK: Helpers

    private var sortedBackends: [VolumeBackend] {
        (registry?.allVolumeBackends ?? []).sorted { $0.id < $1.id }
    }

    private func reload() {
        isLoading = true
        registry = try? FleetRegistry(url: fleetURL)
        isLoading = false
    }

    // MARK: Async actions

    @MainActor
    private func restore(rule: OffloadRule, backend: VolumeBackend) async {
        let key = "\(backend.id):\(rule.source)"
        busyRules.insert(key)
        defer { busyRules.remove(key) }

        let sourcePath = rule.resolvedSource
        let targetPath = rule.target

        // Ensure the target directory exists.
        do {
            try FileManager.default.createDirectory(
                atPath: (targetPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        } catch { /* non-fatal — target dir may already exist */ }

        // Move existing data to target if it's a real directory (not already a symlink).
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDir)
        if exists && isDir.boolValue {
            do {
                try FileManager.default.moveItem(atPath: sourcePath, toPath: targetPath)
            } catch {
                // If target already exists, just remove the source dir.
                try? FileManager.default.removeItem(atPath: sourcePath)
            }
        }

        // Create the symlink.
        do {
            try FileManager.default.createSymbolicLink(atPath: sourcePath, withDestinationPath: targetPath)
            reload()
        } catch {
            errorBanners.append("Restore failed [\(rule.source)]: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func removeRule(rule: OffloadRule, backend: VolumeBackend) async {
        let key = "\(backend.id):\(rule.source)"
        busyRules.insert(key)
        defer { busyRules.remove(key) }

        do {
            try FleetEditor.updateBackend(id: backend.id, at: fleetURL) { drive in
                var syms = drive["symlinks"] as? [String] ?? []
                syms.removeAll { $0.contains(rule.source) }
                drive["symlinks"] = syms
            }
            reload()
        } catch {
            errorBanners.append("Remove failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - AddOffloadRuleSheet

/// Modal form to add a new offload rule to a `VolumeBackend`.
private struct AddOffloadRuleSheet: View {

    let backend: VolumeBackend
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sourceField = "~/"
    @State private var targetField = ""
    @State private var errorMessage: String?

    private var fleetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Rule for \(backend.id)") {
                    TextField("Source (e.g. ~/.tool-cache)", text: $sourceField)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced())

                    TextField("Target (e.g. \(backend.mount)/tool-cache)", text: $targetField)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                }

                Section {
                    Text("This creates an entry in fleet.json `symlinks[]`. Use Restore in the rule manager to actually create the symlink on disk.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let err = errorMessage {
                    Section { Text(err).foregroundStyle(.red).font(.callout) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Offload Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(sourceField.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  targetField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 300)
    }

    private func save() {
        let src = sourceField.trimmingCharacters(in: .whitespaces)
        let tgt = targetField.trimmingCharacters(in: .whitespaces)
        let raw = "\(src) → \(tgt)"

        do {
            try FleetEditor.updateBackend(id: backend.id, at: fleetURL) { drive in
                var syms = drive["symlinks"] as? [String] ?? []
                syms.append(raw)
                drive["symlinks"] = syms
            }
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI
import LFGKit

// MARK: - OffloadRuleRow

/// A single-line row displaying one `OffloadRule` with its symlink health indicator
/// and an inline "Restore" action.
///
/// Layout:
/// ```
/// ● ~/.npm-cache  →  /Volumes/DDRV-901-DEVLIB/npm-cache   [Restore]
/// ```
///
/// The health circle is green when `rule.isHealthy`, red otherwise.
/// Tapping **Restore** removes any existing item at `rule.resolvedSource` and
/// recreates the symlink pointing to `rule.target`. The operation runs on a
/// background `Task` so the main thread is never blocked; any error is surfaced
/// as inline red `Text`.
struct OffloadRuleRow: View {

    // MARK: Input

    let rule: OffloadRule

    /// Optional corruption class for the parent backend. When non-nil, the health dot
    /// color reflects the LFG-93 severity mapping instead of the binary green/red.
    ///
    /// | Class | Color  | Rationale                                |
    /// |-------|--------|------------------------------------------|
    /// | A     | Orange | Transient; autonomous-reclaimable        |
    /// | B     | Red    | Superblock; recovery agent required       |
    /// | C     | Red    | Metadata destroyed; data at risk          |
    /// | D     | Red    | Band damage; partial data loss possible   |
    /// | E     | Yellow | Permission ghost; data intact             |
    var corruptionClass: CorruptionClass? = nil

    // MARK: State

    @State private var isRestoring = false
    @State private var restoreError: String?

    // MARK: Health dot color

    private var healthDotColor: Color {
        if rule.isHealthy { return .green }
        switch corruptionClass {
        case .classA: return .orange
        case .classB, .classC, .classD: return .red
        case .classE: return .yellow
        case nil: return .red  // unknown / legacy
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Health indicator — uses corruption-class color when available
                Circle()
                    .fill(healthDotColor)
                    .frame(width: 7, height: 7)

                // Source path
                Text(rule.source)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // Target path — truncated from the left so the filename is visible
                Text(rule.target)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 0)

                // Restore action
                if isRestoring {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 50)
                } else {
                    Button("Restore") {
                        performRestore()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .disabled(rule.isHealthy)
                    .help(rule.isHealthy ? "Symlink is healthy" : "Re-create the symlink at \(rule.resolvedSource)")
                }
            }

            // Inline error, only shown when restore fails
            if let error = restoreError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 15)
            }
        }
        .padding(.leading, 8)
        .animation(.easeInOut(duration: 0.2), value: isRestoring)
        .animation(.easeInOut(duration: 0.15), value: rule.isHealthy)
    }

    // MARK: Restore

    private func performRestore() {
        isRestoring = true
        restoreError = nil

        Task {
            let result = await restoreSymlink(rule: rule)
            await MainActor.run {
                isRestoring = false
                restoreError = result
            }
        }
    }
}

// MARK: - Symlink restore logic (nonisolated, safe for background Task)

/// Removes any existing item at `rule.resolvedSource` and creates a new symlink
/// pointing to `rule.target`.
///
/// - Returns: An error description string on failure, or `nil` on success.
private func restoreSymlink(rule: OffloadRule) async -> String? {
    let sourcePath = rule.resolvedSource
    let fm = FileManager.default

    do {
        // Remove whatever is at the source path (symlink, file, or directory).
        if fm.fileExists(atPath: sourcePath) || (try? fm.destinationOfSymbolicLink(atPath: sourcePath)) != nil {
            try fm.removeItem(atPath: sourcePath)
        }
        try fm.createSymbolicLink(atPath: sourcePath, withDestinationPath: rule.target)
        return nil
    } catch {
        return error.localizedDescription
    }
}

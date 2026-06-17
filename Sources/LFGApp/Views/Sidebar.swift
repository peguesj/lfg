import SwiftUI

/// Primary sidebar listing all LFG modules with status badge indicators.
///
/// Each module row shows a coloured status dot derived from `AppState.moduleStatuses`
/// so the user can see at a glance which modules are running or have errors.
struct LFGSidebar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(selection: Bindable(appState).selectedModule) {
            Section("Dashboard") {
                NavigationLink(value: Optional<LFGModule>.none) {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
                .tag(Optional<LFGModule>.none)
            }

            Section("Modules") {
                ForEach(LFGModule.allCases) { module in
                    NavigationLink(value: Optional(module)) {
                        LFGSidebarRow(module: module, status: appState.moduleStatuses[module])
                    }
                    .tag(Optional(module))
                }
            }
        }
        .navigationTitle("LFG")
    }
}

// MARK: - LFGSidebarRow

/// One module row: icon + name on the left, status badge on the right.
private struct LFGSidebarRow: View {
    let module: LFGModule
    let status: ModuleStatus?

    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(module.rawValue)
            } icon: {
                Image(systemName: module.icon)
                    .foregroundStyle(module.color)
            }
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let state = status?.state ?? .idle
        switch state {
        case .idle:
            EmptyView()
        case .running:
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 16, height: 16)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

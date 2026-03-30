import SwiftUI
import LFGKit

struct DashboardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                diskOverview
                moduleGrid
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        .onAppear { appState.updateDiskInfo() }
    }

    private var diskOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disk Usage")
                .font(.headline)

            ProgressView(value: appState.diskUsagePercent, total: 100)
                .tint(appState.diskUsagePercent > 90 ? .red : .blue)

            HStack {
                Text("\(SizeFormatter.format(appState.usedDiskSpace)) used")
                Spacer()
                Text("\(SizeFormatter.format(appState.freeDiskSpace)) free")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(SizeFormatter.format(appState.totalDiskSpace)) total")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var moduleGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
        ], spacing: 16) {
            ForEach(LFGModule.allCases) { module in
                moduleCard(module)
            }
        }
    }

    private func moduleCard(_ module: LFGModule) -> some View {
        let status = appState.moduleStatuses[module] ?? ModuleStatus()
        return VStack(spacing: 8) {
            Image(systemName: module.icon)
                .font(.title)
                .foregroundStyle(module.color)

            Text(module.rawValue)
                .font(.headline)

            Text(module.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(status.state.rawValue.capitalized)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(statusColor(status.state).opacity(0.2), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusColor(_ state: ModuleRunState) -> Color {
        switch state {
        case .idle: .gray
        case .running: .blue
        case .completed: .green
        case .error: .red
        }
    }
}

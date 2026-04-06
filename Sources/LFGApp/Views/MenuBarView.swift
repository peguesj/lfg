import SwiftUI
import LFGKit

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LFG - Local File Guardian")
                .font(.headline)

            Divider()

            diskRow

            Divider()

            ForEach(LFGModule.allCases) { module in
                let status = appState.moduleStatuses[module] ?? ModuleStatus()
                HStack {
                    Image(systemName: module.icon)
                        .foregroundStyle(module.color)
                        .frame(width: 20)
                    Text(module.rawValue)
                    Spacer()
                    Text(status.state.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Open LFG") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
        .onAppear { appState.updateDiskInfo() }
    }

    private var diskRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Disk")
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.0f%%", appState.diskUsagePercent))
                    .font(.caption)
            }
            ProgressView(value: appState.diskUsagePercent, total: 100)
                .tint(appState.diskUsagePercent > 90 ? .red : .blue)
            Text("\(SizeFormatter.format(appState.freeDiskSpace)) free of \(SizeFormatter.format(appState.totalDiskSpace))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

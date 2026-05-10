import SwiftUI

/// Top-level DevDrive view. Presents the two operational sub-panels via
/// a tab view so users can switch between volume management and live
/// pressure monitoring without leaving the module.
struct DevDriveView: View {

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DevDriveOperationsView()
                .tabItem {
                    Label("Volumes", systemImage: "externaldrive.fill")
                }
                .tag(0)

            PressureMonitorView()
                .tabItem {
                    Label("Pressure", systemImage: "chart.xyaxis.line")
                }
                .tag(1)
        }
        .navigationTitle("DevDrive")
    }
}

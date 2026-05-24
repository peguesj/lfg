import SwiftUI
import SwiftData
import UserNotifications

@main
struct LFGApp: App {
    @State private var appState = AppState()

    init() {
        // UNUserNotificationCenter requires a bundle identifier — skip when running as a bare CLI executable.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            DiskSnapshot.self,
            VolumeProfile.self,
            InboxItem.self,
        ])
        let config = ModelConfiguration(
            "LFG",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appState)
                .onAppear {
                    appState.setupMountWatcher()
                }
        }
        .modelContainer(sharedModelContainer)

        MenuBarExtra("LFG", systemImage: "externaldrive.fill") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            LFGSidebar()
        } detail: {
            detailView
        }
        .frame(minWidth: 800, minHeight: 540)
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedModule {
        case .none:
            DashboardView()
        case .devdrive:
            DevDriveView()
        case .wtfs:
            WTFSView()
        case .dtf:
            DTFView()
        case .btau:
            BTAUView()
        case .ssd:
            SSDView()
        }
    }
}

import SwiftUI
import SwiftData
import UserNotifications

@main
struct LFGApp: App {
    @State private var appState = AppState()

    /// Auto-attach all auto-policy sparseimages whose host volume is already mounted
    /// when LFG launches. Default ON so that the menubar app re-establishes the
    /// DevDrive fabric automatically on every login.
    @AppStorage("lfg.autoAttachOnLaunch") private var autoAttachOnLaunch = true

    init() {
        // UNUserNotificationCenter requires a bundle identifier — skip when running as a bare CLI executable.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        DevDriveNotificationCategories.registerCategories()
        UNUserNotificationCenter.current().delegate = NotificationActionHandler.shared
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
                    if autoAttachOnLaunch {
                        Task { await appState.attachAllMountedHosts() }
                    }
                }
        }
        .modelContainer(sharedModelContainer)

        MenuBarExtra("LFG", systemImage: "externaldrive.fill") {
            MenuBarView()
                .environment(appState)
                .onAppear {
                    // MenuBarExtra is the canonical launch surface for LSUIElement apps;
                    // the WindowGroup may never appear if the user never opens the main
                    // window. Wire mount watcher + auto-attach here so persistence works
                    // for menubar-only sessions.
                    appState.setupMountWatcher()
                    if autoAttachOnLaunch {
                        Task { await appState.attachAllMountedHosts() }
                    }
                }
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

import SwiftUI
import SwiftData

@main
struct LFGApp: App {
    @State private var appState = AppState()

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
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .modelContainer(sharedModelContainer)

        MenuBarExtra("LFG", systemImage: "externaldrive.fill") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            DashboardView()
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

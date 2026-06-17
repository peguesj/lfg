import SwiftUI

struct Sidebar: View {
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
                        Label {
                            Text(module.rawValue)
                        } icon: {
                            Image(systemName: module.icon)
                                .foregroundStyle(module.color)
                        }
                    }
                    .tag(Optional(module))
                }
            }
        }
        .navigationTitle("LFG")
    }
}

import SwiftUI

struct SettingsView: View {
    @State private var launchAtLogin = LoginItemManager.isEnabled()
    @State private var loginError: String?
    @State private var hasFullDiskAccess = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450, height: 300)
        .onAppear { checkFDA() }
    }

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch LFG at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItemManager.setEnabled(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = !newValue
                        }
                    }
                if let err = loginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: hasFullDiskAccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasFullDiskAccess ? .green : .red)
                    Text(hasFullDiskAccess ? "Full Disk Access granted" : "Full Disk Access required")
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
                Text("Required for scanning system caches and managing Spotlight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Text("LFG").font(.largeTitle.bold())
            Text("Local File Guardian").font(.headline).foregroundStyle(.secondary)
            Divider()
            LabeledContent("Version", value: "2.5.0")
            LabeledContent("Bundle ID", value: "io.pegues.yj.lfg")
            LabeledContent("Platform", value: "macOS 14+")
        }
        .padding()
    }

    private func checkFDA() {
        let testPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail").path
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: testPath)
    }
}

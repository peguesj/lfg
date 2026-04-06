import SwiftUI
import Charts

struct DTFView: View {
    @State private var caches: [CacheDiscoveryService.CacheTarget] = []
    @State private var selected = Set<UUID>()
    @State private var isScanning = false
    @State private var statusMessage: String?

    private let service = CacheDiscoveryService()

    private var totalSize: Int64 { caches.reduce(0) { $0 + $1.sizeBytes } }
    private var selectedSize: Int64 { caches.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Delete Temp Files").font(.title2.bold())
                Spacer()
                Button(action: { Task { await discover() } }) { Label("Scan", systemImage: "arrow.clockwise") }
                    .disabled(isScanning)
                if !caches.isEmpty {
                    Button(role: .destructive, action: { Task { await clean() } }) {
                        Label("Clean Selected", systemImage: "trash")
                    }.disabled(selected.isEmpty)
                }
            }

            if isScanning {
                ProgressView("Discovering caches...").frame(maxWidth: .infinity)
            } else if caches.isEmpty {
                ContentUnavailableView("No Caches", systemImage: "trash.slash",
                                       description: Text("Click Scan to discover reclaimable caches"))
            } else {
                HStack(spacing: 16) {
                    statCard("Total", ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                    statCard("Selected", ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))
                    statCard("Categories", "\(Set(caches.map(\.category)).count)")
                }

                List(caches, selection: $selected) { cache in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(cache.name).font(.headline)
                            Text(cache.path.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(cache.category.rawValue).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue.opacity(0.15)).clipShape(Capsule())
                        Text(cache.sizeFormatted).monospacedDigit().bold()
                    }
                }

                if let msg = statusMessage { Text(msg).font(.footnote).foregroundStyle(.green) }
            }
        }
        .padding()
        .navigationTitle("DTF")
    }

    private func discover() async {
        isScanning = true; statusMessage = nil
        caches = await service.discover()
        isScanning = false
    }

    private func clean() async {
        let targets = caches.filter { selected.contains($0.id) }
        let result = await service.clean(targets: targets)
        statusMessage = "Freed \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file))"
        selected.removeAll()
        await discover()
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding().background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

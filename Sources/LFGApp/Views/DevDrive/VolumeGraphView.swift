import SwiftUI
import LFGKit

// MARK: - GraphNodeType

/// Classifies a node in the volume graph for layout and colouring purposes.
enum GraphNodeType {
    /// A physical host volume (SourceVolume or the synthetic "Internal" node).
    case source
    /// A sparseimage-backed APFS volume with an associated health status.
    case backend(VolumeStatus)
    /// An offload symlink rule; `isHealthy` drives the border tint.
    case rule(Bool)
}

// MARK: - GraphNodeLayout

/// Pre-computed geometry and metadata for one node in the graph canvas.
///
/// Positions are in the coordinate space of the full canvas, which is embedded
/// inside a `ScrollView(.both)` so the entire graph can be panned.
struct GraphNodeLayout: Identifiable {
    let id: UUID
    let label: String
    let sublabel: String
    let type: GraphNodeType
    /// Centre-X of the node in canvas coordinates.
    let x: CGFloat
    /// Centre-Y of the node in canvas coordinates.
    let y: CGFloat

    // MARK: Geometry helpers

    var size: CGSize {
        switch type {
        case .source:          return CGSize(width: 120, height: 50)
        case .backend:         return CGSize(width: 110, height: 48)
        case .rule:            return CGSize(width: 100, height: 38)
        }
    }

    /// The rect whose origin is the top-left corner of the node.
    var rect: CGRect {
        CGRect(
            x: x - size.width  / 2,
            y: y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The absolute centre point — used for edge drawing.
    var center: CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - GraphEdge

/// A directed edge from a parent node to a child node.
private struct GraphEdge {
    let parentID: UUID
    let childID: UUID
}

// MARK: - GraphLayout

/// Computes the static three-tier layout from a `FleetRegistry`.
///
/// Layout tiers (Y positions):
/// - Tier 0 (sources):  y = 60
/// - Tier 1 (backends): y = 200
/// - Tier 2 (rules):    y = 340
private enum GraphLayout {

    // MARK: Constants

    private static let tier0Y:        CGFloat = 60
    private static let tier1Y:        CGFloat = 200
    private static let tier2Y:        CGFloat = 340
    private static let sourceSpacing: CGFloat = 180
    private static let leftMargin:    CGFloat = 100

    // MARK: Build

    /// Returns the full set of nodes and edges, plus the total canvas size.
    static func build(from registry: FleetRegistry) -> (
        nodes: [GraphNodeLayout],
        edges: [GraphEdge],
        canvasSize: CGSize
    ) {
        var nodes: [GraphNodeLayout] = []
        var edges: [GraphEdge] = []

        // Identify known source names and their ordering.
        let knownHosts = Set(registry.allSourceVolumes.map(\.name))
        var sourceNames: [String] = registry.allSourceVolumes
            .sorted { $0.name < $1.name }
            .map(\.name)

        // Collect backends that belong to no known external source → "Internal" group.
        let internalBackends = registry.allVolumeBackends.filter { !knownHosts.contains($0.host) }
        if !internalBackends.isEmpty {
            sourceNames.append("internal")
        }

        // Build source nodes — evenly spaced across the top row.
        var sourceNodeByName: [String: GraphNodeLayout] = [:]

        for (index, sourceName) in sourceNames.enumerated() {
            let x = leftMargin + CGFloat(index) * sourceSpacing
            let isMounted: Bool
            let displayName: String
            if sourceName == "internal" {
                isMounted = true
                displayName = "Internal"
            } else {
                let sv = registry.sourceVolume(named: sourceName)
                isMounted = sv?.isMounted ?? false
                displayName = sourceName
            }

            let sublabel = isMounted ? "mounted" : "not mounted"
            let node = GraphNodeLayout(
                id: UUID(),
                label: displayName,
                sublabel: sublabel,
                type: .source,
                x: x,
                y: tier0Y
            )
            nodes.append(node)
            sourceNodeByName[sourceName] = node
        }

        // Build backend nodes — grouped under their source, centred below parent.
        var backendNodeByID: [String: GraphNodeLayout] = [:]
        // Accumulate backend X positions per source to centre them under the parent.
        let backendSpacing: CGFloat = 130

        for sourceName in sourceNames {
            guard let sourceNode = sourceNodeByName[sourceName] else { continue }

            let backends: [VolumeBackend]
            if sourceName == "internal" {
                backends = internalBackends.sorted { $0.id < $1.id }
            } else {
                backends = registry.volumeBackends(forHost: sourceName).sorted { $0.id < $1.id }
            }
            guard !backends.isEmpty else { continue }

            // Compute X positions centred under the source node.
            let totalWidth = CGFloat(backends.count - 1) * backendSpacing
            let startX = sourceNode.x - totalWidth / 2

            for (bIndex, backend) in backends.enumerated() {
                let bx = startX + CGFloat(bIndex) * backendSpacing
                let status = VolumeStatus.derive(from: backend)
                let node = GraphNodeLayout(
                    id: UUID(),
                    label: backend.id,
                    sublabel: backend.mount,
                    type: .backend(status),
                    x: bx,
                    y: tier1Y
                )
                nodes.append(node)
                backendNodeByID[backend.id] = node
                edges.append(GraphEdge(parentID: sourceNode.id, childID: node.id))
            }
        }

        // Build offload rule nodes — grouped under their backend.
        let ruleSpacing: CGFloat = 115

        for sourceName in sourceNames {
            let backends: [VolumeBackend]
            if sourceName == "internal" {
                backends = internalBackends.sorted { $0.id < $1.id }
            } else {
                backends = registry.volumeBackends(forHost: sourceName).sorted { $0.id < $1.id }
            }

            for backend in backends {
                guard let backendNode = backendNodeByID[backend.id] else { continue }
                let rules = backend.offloadRules
                guard !rules.isEmpty else { continue }

                let totalWidth = CGFloat(rules.count - 1) * ruleSpacing
                let startX = backendNode.x - totalWidth / 2

                for (rIndex, rule) in rules.enumerated() {
                    let rx = startX + CGFloat(rIndex) * ruleSpacing
                    let node = GraphNodeLayout(
                        id: UUID(),
                        label: rule.source,
                        sublabel: rule.target,
                        type: .rule(rule.isHealthy),
                        x: rx,
                        y: tier2Y
                    )
                    nodes.append(node)
                    edges.append(GraphEdge(parentID: backendNode.id, childID: node.id))
                }
            }
        }

        // Determine canvas dimensions from node extents.
        let padding: CGFloat = 60
        let maxX = nodes.map { $0.x + $0.size.width / 2 }.max() ?? 400
        let maxY = nodes.map { $0.y + $0.size.height / 2 }.max() ?? 400
        let canvasSize = CGSize(width: maxX + padding, height: maxY + padding)

        return (nodes: nodes, edges: edges, canvasSize: canvasSize)
    }
}

// MARK: - GraphNodeView

/// A single tappable node rectangle in the graph.
private struct GraphNodeView: View {

    let node: GraphNodeLayout
    let onTap: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(fillColor)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: 1.5)
            VStack(spacing: 2) {
                Text(node.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.sublabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: node.size.width, height: node.size.height)
        .onTapGesture { onTap() }
    }

    // MARK: Colour helpers

    private var fillColor: Color {
        switch node.type {
        case .source:
            return .blue.opacity(0.15)
        case .backend(let status):
            return statusFill(status)
        case .rule:
            return .purple.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch node.type {
        case .source:
            return .blue
        case .backend(let status):
            return statusBorder(status)
        case .rule(let healthy):
            return healthy ? .purple : .orange
        }
    }

    private func statusFill(_ status: VolumeStatus) -> Color {
        switch status {
        case .healthy:   return .green.opacity(0.15)
        case .drift:     return .orange.opacity(0.15)
        case .error:     return .red.opacity(0.15)
        case .unmounted: return Color.secondary.opacity(0.12)
        }
    }

    private func statusBorder(_ status: VolumeStatus) -> Color {
        switch status {
        case .healthy:   return .green
        case .drift:     return .orange
        case .error:     return .red
        case .unmounted: return .secondary
        }
    }
}

// MARK: - NodePopoverContent

/// Summary card shown in a popover when a node is tapped.
private struct NodePopoverContent: View {

    let node: GraphNodeLayout
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(node.label)
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ForEach(summaryRows, id: \.0) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    Text(row.1)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 260, maxWidth: 320)
    }

    private var summaryRows: [(String, String)] {
        switch node.type {
        case .source:
            return [
                ("Type",   "Source Volume"),
                ("Status", node.sublabel),
                ("Name",   node.label)
            ]
        case .backend(let status):
            return [
                ("Type",   "Volume Backend"),
                ("Mount",  node.sublabel),
                ("Status", statusLabel(status))
            ]
        case .rule(let healthy):
            return [
                ("Type",    "Offload Rule"),
                ("Source",  node.label),
                ("Target",  node.sublabel),
                ("Health",  healthy ? "Healthy" : "Broken")
            ]
        }
    }

    private func statusLabel(_ status: VolumeStatus) -> String {
        switch status {
        case .healthy:   return "Healthy"
        case .drift:     return "Drift Detected"
        case .error:     return "Error"
        case .unmounted: return "Unmounted"
        }
    }
}

// MARK: - VolumeGraphView

/// A static hierarchical graph of the DevDrive fleet.
///
/// Renders three tiers top-to-bottom inside a bidirectional `ScrollView`:
///
/// ```
/// Tier 0: SourceVolume nodes  (blue)
///              |
/// Tier 1: VolumeBackend nodes (green/orange/red/gray per VolumeStatus)
///              |
/// Tier 2: OffloadRule nodes   (purple)
/// ```
///
/// Edge lines are drawn on a `Canvas` layer behind all nodes. Tapping any node
/// shows a popover summary card.
struct VolumeGraphView: View {

    let registry: FleetRegistry

    // MARK: State

    @State private var nodes: [GraphNodeLayout] = []
    @State private var edges: [GraphEdge] = []
    @State private var canvasSize: CGSize = .zero
    @State private var selectedNode: GraphNodeLayout?

    // MARK: Body

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                edgeCanvas
                nodesLayer
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task { buildLayout() }
    }

    // MARK: Edge canvas

    /// Full-size `Canvas` drawn below the node layer. Not hit-testable.
    private var edgeCanvas: some View {
        Canvas { context, _ in
            let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            var path = Path()
            for edge in edges {
                guard
                    let parent = nodeMap[edge.parentID],
                    let child  = nodeMap[edge.childID]
                else { continue }
                path.move(to: parent.center)
                path.addLine(to: child.center)
            }
            context.stroke(
                path,
                with: .color(.secondary.opacity(0.4)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    // MARK: Nodes layer

    private var nodesLayer: some View {
        ForEach(nodes) { node in
            GraphNodeView(node: node) {
                selectedNode = node
            }
            .position(x: node.x, y: node.y)
            .popover(
                isPresented: Binding(
                    get: { selectedNode?.id == node.id },
                    set: { if !$0 { selectedNode = nil } }
                ),
                arrowEdge: .bottom
            ) {
                NodePopoverContent(node: node) { selectedNode = nil }
            }
        }
    }

    // MARK: Layout computation

    private func buildLayout() {
        let result = GraphLayout.build(from: registry)
        nodes = result.nodes
        edges = result.edges
        canvasSize = result.canvasSize
    }
}


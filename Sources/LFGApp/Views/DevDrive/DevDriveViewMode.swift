import SwiftUI

// MARK: - DevDriveViewMode

/// The three display modes available in ``DevDriveView``.
///
/// The selected mode is persisted via `@AppStorage` so it survives app restarts.
///
/// ```swift
/// @AppStorage("devDriveViewMode") private var viewMode: DevDriveViewMode = .list
/// ```
public enum DevDriveViewMode: String, CaseIterable {

    // MARK: Cases

    /// A classic collapsible list grouped by source volume.
    case list

    /// An interactive card grid with inline capacity and status indicators.
    case card

    /// A node-relationship graph showing volume connections and offload rules.
    case graph

    // MARK: Display properties

    /// Human-readable label shown in the segmented picker and accessibility text.
    public var label: String {
        switch self {
        case .list:  return "List"
        case .card:  return "Card"
        case .graph: return "Graph"
        }
    }

    /// SF Symbol name representing this mode in the toolbar picker.
    public var systemImage: String {
        switch self {
        case .list:  return "list.bullet"
        case .card:  return "rectangle.grid.2x2"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

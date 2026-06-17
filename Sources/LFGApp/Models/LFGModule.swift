import SwiftUI

enum LFGModule: String, CaseIterable, Identifiable, Codable {
    case wtfs = "WTFS"
    case dtf = "DTF"
    case btau = "BTAU"
    case devdrive = "DevDrive"
    case ssd = "SSD"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wtfs: "Where's The Free Space"
        case .dtf: "Delete Temporary Files"
        case .btau: "Backup Then Archive Unused"
        case .devdrive: "Developer Drive"
        case .ssd: "Spotlight SSD Manager"
        }
    }

    var icon: String {
        switch self {
        case .wtfs: "chart.pie.fill"
        case .dtf: "trash.fill"
        case .btau: "externaldrive.fill.badge.timemachine"
        case .devdrive: "hammer.fill"
        case .ssd: "magnifyingglass"
        }
    }

    var color: Color {
        switch self {
        case .wtfs: .blue
        case .dtf: .orange
        case .btau: .green
        case .devdrive: .purple
        case .ssd: .teal
        }
    }
}

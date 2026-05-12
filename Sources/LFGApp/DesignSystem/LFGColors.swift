import SwiftUI

/// Semantic color tokens for LFG. All values degrade gracefully if the
/// named asset is missing — each has a hard-coded adaptive fallback.
enum LFGColors {
    // MARK: - Status

    /// Green: volume is mounted / operation succeeded.
    static let mounted = Color.green

    /// Orange: approaching a threshold / needs attention.
    static let warning = Color.orange

    /// Red: error or critical state.
    static let error = Color.red

    // MARK: - Surface

    /// Primary background — adapts to light/dark automatically.
    static let surface = Color(nsColor: .windowBackgroundColor)

    /// Secondary grouped surface (slightly raised card).
    static let surfaceSecondary = Color(nsColor: .controlBackgroundColor)

    // MARK: - Accent

    /// LFG brand accent: electric cyan.
    static let accent = Color(red: 0, green: 0.784, blue: 1) // #00C8FF

    // MARK: - Semantic extras

    static let success = Color.green
    static let danger  = Color.red

    // MARK: - Text

    static let textPrimary   = Color.primary
    static let textSecondary = Color.secondary
}

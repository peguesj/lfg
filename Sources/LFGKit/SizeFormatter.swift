import Foundation

/// Human-readable byte size formatting.
public struct SizeFormatter {
    private static let units: [(String, UInt64)] = [
        ("TB", 1_099_511_627_776),
        ("GB", 1_073_741_824),
        ("MB", 1_048_576),
        ("KB", 1_024),
    ]

    /// Format a byte count as a human-readable string (e.g. "42.3 GB").
    public static func format(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }

        for (unit, threshold) in units {
            if bytes >= threshold {
                let value = Double(bytes) / Double(threshold)
                return String(format: "%.1f %@", value, unit)
            }
        }
        return "\(bytes) B"
    }

    /// Parse a human-readable size string back to bytes.
    /// Supports formats like "42.3 GB", "100MB", "1.5 TB".
    public static func parse(_ string: String) -> UInt64? {
        let trimmed = string.trimmingCharacters(in: .whitespaces).uppercased()

        for (unit, multiplier) in units {
            if trimmed.hasSuffix(unit) {
                let numberPart = trimmed.dropLast(unit.count)
                    .trimmingCharacters(in: .whitespaces)
                guard let value = Double(numberPart) else { return nil }
                return UInt64(value * Double(multiplier))
            }
        }

        if trimmed.hasSuffix("B") {
            let numberPart = trimmed.dropLast(1).trimmingCharacters(in: .whitespaces)
            return UInt64(numberPart)
        }

        return UInt64(trimmed)
    }
}

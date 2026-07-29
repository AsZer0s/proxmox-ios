import Foundation
import SwiftUI

// MARK: - String

extension String {
    /// Percent-encodes the string for use in an
    /// `application/x-www-form-urlencoded` body. `+`, `&`, `=` and space must
    /// all be escaped, which the built-in `.urlQueryAllowed` set does not do.
    var formURLEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    /// Whitespace- and newline-trimmed copy of the string.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

// MARK: - Byte / percent / duration formatting

extension Int64 {
    /// Human-readable byte size, e.g. `1.5 GB`.
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .memory)
    }
}

extension Optional where Wrapped == Int64 {
    var formattedBytes: String {
        guard let value = self else { return "—" }
        return value.formattedBytes
    }
}

extension Double {
    /// Formats a 0...1 fraction as a percentage, e.g. `0.42` -> `42%`.
    var asPercent: String {
        String(format: "%.0f%%", self * 100)
    }

    /// Formats a 0...1 fraction with one decimal, e.g. `0.421` -> `42.1%`.
    var asPercentDetailed: String {
        String(format: "%.1f%%", self * 100)
    }
}

extension Optional where Wrapped == Double {
    var asPercent: String {
        guard let value = self else { return "—" }
        return value.asPercent
    }
}

extension Int64 {
    /// Formats an uptime in seconds as `3d 4h 12m`.
    var formattedUptime: String {
        guard self > 0 else { return "—" }
        let days = self / 86_400
        let hours = (self % 86_400) / 3_600
        let minutes = (self % 3_600) / 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }
        return parts.joined(separator: " ")
    }
}

extension Optional where Wrapped == Int64 {
    var formattedUptime: String {
        guard let value = self else { return "—" }
        return value.formattedUptime
    }
}

// MARK: - Color helpers

extension Color {
    /// Status color for a running/stopped/online/offline string.
    static func forStatus(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "running", "online":
            return .green
        case "stopped", "offline":
            return .secondary
        case "paused", "suspended":
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - View helpers

extension View {
    /// Applies a closure-based transform only when `condition` is true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

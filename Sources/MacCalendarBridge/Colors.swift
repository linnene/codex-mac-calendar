import AppKit
import Foundation

/// Calendar and reminder-list colours.
///
/// EventKit stores container colours as `NSColor`, so both directions go
/// through sRGB hex. The palette mirrors the macOS system colour set, which is
/// what Calendar.app itself offers.
enum Colors {

    struct Swatch {
        let name: String
        let alias: String
        let hex: String
    }

    static let palette: [Swatch] = [
        Swatch(name: "red", alias: "红", hex: "#FF3B30"),
        Swatch(name: "orange", alias: "橙", hex: "#FF9500"),
        Swatch(name: "yellow", alias: "黄", hex: "#FFCC00"),
        Swatch(name: "green", alias: "绿", hex: "#34C759"),
        Swatch(name: "mint", alias: "薄荷", hex: "#00C7BE"),
        Swatch(name: "teal", alias: "青绿", hex: "#30B0C7"),
        Swatch(name: "cyan", alias: "青", hex: "#32ADE6"),
        Swatch(name: "blue", alias: "蓝", hex: "#007AFF"),
        Swatch(name: "indigo", alias: "靛蓝", hex: "#5856D6"),
        Swatch(name: "purple", alias: "紫", hex: "#AF52DE"),
        Swatch(name: "pink", alias: "粉", hex: "#FF2D55"),
        Swatch(name: "brown", alias: "棕", hex: "#A2845E"),
        Swatch(name: "gray", alias: "灰", hex: "#8E8E93"),
        Swatch(name: "graphite", alias: "石墨", hex: "#636366"),
        Swatch(name: "charcoal", alias: "炭黑", hex: "#48484A"),
        Swatch(name: "silver", alias: "银", hex: "#AEAEB2"),
    ]

    /// Names that resolve to a palette swatch, including a few common synonyms.
    private static let synonyms: [String: String] = [
        "systemred": "red", "crimson": "red",
        "systemorange": "orange",
        "systemyellow": "yellow",
        "systemgreen": "green",
        "systemmint": "mint",
        "systemteal": "teal",
        "systemcyan": "cyan",
        "systemblue": "blue",
        "systemindigo": "indigo",
        "systempurple": "purple",
        "systempink": "pink",
        "systembrown": "brown",
        "systemgray": "gray", "grey": "gray", "系统灰": "gray",
        "purple2": "purple",
        "红色": "red", "橙色": "orange", "黄色": "yellow", "绿色": "green",
        "蓝色": "blue", "紫色": "purple", "粉色": "pink", "棕色": "brown",
        "灰色": "gray", "黑色": "charcoal", "青色": "cyan",
    ]

    static func hex(_ color: NSColor?) -> String? {
        guard let color else { return nil }
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        let alpha = Int((converted.alphaComponent * 255).rounded())
        let base = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha >= 255 ? base : base + String(format: "%02X", alpha)
    }

    static func color(_ value: String) throws -> NSColor {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()

        if let swatch = palette.first(where: { $0.name == lowered || $0.alias == text }) {
            return try color(swatch.hex)
        }
        if let mapped = synonyms[lowered], let swatch = palette.first(where: { $0.name == mapped }) {
            return try color(swatch.hex)
        }

        var hexText = text
        if hexText.hasPrefix("#") { hexText.removeFirst() }
        hexText = hexText.uppercased()
        guard hexText.count == 3 || hexText.count == 6 || hexText.count == 8,
              hexText.allSatisfy({ $0.isHexDigit }) else {
            throw BridgeError.invalid(
                "Unknown colour '\(value)'.",
                "Pass a hex value ('#FF9500') or a palette name (\(palette.map(\.name).joined(separator: ", ")))."
            )
        }
        if hexText.count == 3 {
            hexText = hexText.map { "\($0)\($0)" }.joined()
        }
        let scanner = Scanner(string: hexText)
        var value64: UInt64 = 0
        guard scanner.scanHexInt64(&value64) else {
            throw BridgeError.invalid("Unknown colour '\(value)'.", nil)
        }
        let hasAlpha = hexText.count == 8
        let red = CGFloat((value64 >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value64 >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value64 >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value64 & 0xFF) / 255 : 1
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func paletteResult(query: String? = nil) -> [String: Any] {
        var swatches = palette
        if let query, !query.isEmpty {
            let needle = query.lowercased()
            swatches = palette.filter {
                $0.name.contains(needle) || $0.alias.contains(query)
            }
        }
        return [
            "source": "macOS system palette",
            "count": swatches.count,
            "colors": swatches.map { ["name": $0.name, "alias": $0.alias, "hex": $0.hex] },
            "note": "Container colours are stored by EventKit as sRGB NSColor values; hex round-trips losslessly.",
        ]
    }
}

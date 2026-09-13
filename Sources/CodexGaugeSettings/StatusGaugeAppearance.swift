import Foundation

public struct StatusGaugeColor: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    init?(hexString: String) {
        guard hexString.count == 7, hexString.first == "#" else {
            return nil
        }
        guard let value = UInt32(hexString.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }
}

public enum StatusGaugePreset: String, CaseIterable, Equatable, Hashable, Sendable {
    case neutral
    case blue
    case graphite
    case green
    case orange
    case purple

    public var borderColor: StatusGaugeColor {
        switch self {
        case .neutral:
            StatusGaugeColor(red: 0xA5, green: 0xAC, blue: 0xB6)
        case .blue:
            StatusGaugeColor(red: 0x00, green: 0x4C, blue: 0x99)
        case .graphite:
            StatusGaugeColor(red: 0x34, green: 0x3A, blue: 0x40)
        case .green:
            StatusGaugeColor(red: 0x14, green: 0x7A, blue: 0x3D)
        case .orange:
            StatusGaugeColor(red: 0xB8, green: 0x4F, blue: 0x00)
        case .purple:
            StatusGaugeColor(red: 0x75, green: 0x31, blue: 0xA8)
        }
    }

    public var fillColor: StatusGaugeColor {
        switch self {
        case .neutral:
            StatusGaugeColor(red: 0xD8, green: 0xDE, blue: 0xE6)
        case .blue:
            StatusGaugeColor(red: 0x0A, green: 0x84, blue: 0xFF)
        case .graphite:
            StatusGaugeColor(red: 0x7B, green: 0x84, blue: 0x90)
        case .green:
            StatusGaugeColor(red: 0x30, green: 0xD1, blue: 0x58)
        case .orange:
            StatusGaugeColor(red: 0xFF, green: 0x9F, blue: 0x0A)
        case .purple:
            StatusGaugeColor(red: 0xBF, green: 0x5A, blue: 0xF2)
        }
    }
}

public enum StatusGaugeAppearance: Equatable, Hashable, Sendable {
    case preset(StatusGaugePreset)
    case custom(
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor
    )

    public static let `default` = StatusGaugeAppearance.preset(.neutral)

    public var borderColor: StatusGaugeColor {
        switch self {
        case .preset(let preset):
            preset.borderColor
        case .custom(let borderColor, _):
            borderColor
        }
    }

    public var fillColor: StatusGaugeColor {
        switch self {
        case .preset(let preset):
            preset.fillColor
        case .custom(_, let fillColor):
            fillColor
        }
    }
}

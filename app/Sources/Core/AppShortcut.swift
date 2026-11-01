import Foundation

struct AppShortcut: Equatable, Sendable {
    static let functionKeys: [UInt32: Int] = [122:1,120:2,99:3,118:4,96:5,97:6,98:7,100:8,101:9,109:10,103:11,111:12,105:13,107:14,113:15,106:16,64:17,79:18,80:19,90:20]
    var menuKey: String {
        if let number = Self.functionKeys[keyCode] { return String(UnicodeScalar(0xF703 + number)!) }
        return switch keyCode {
        case 49: " "
        case 36: "\r"
        case 76: "\u{3}"
        case 48: "\t"
        case 51: "\u{8}"
        case 123: "\u{F702}"
        case 124: "\u{F703}"
        case 125: "\u{F701}"
        case 126: "\u{F700}"
        case 117: "\u{F728}"
        case 115: "\u{F729}"
        case 119: "\u{F72B}"
        case 116: "\u{F72C}"
        case 121: "\u{F72D}"
        default: key.lowercased()
        }
    }
    var keyCode: UInt32
    var modifiers: UInt
    var key: String
    static let control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20, shift: UInt = 1 << 17
    static let initial = AppShortcut(keyCode: 2, modifiers: control | option, key: "D")
    var valid: Bool { modifiers & (Self.control | Self.option | Self.command) != 0 && !key.isEmpty }
    var display: String {
        keyCaps.joined()
    }
    var keyCaps: [String] { [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")].filter { modifiers & $0.0 != 0 }.map(\.1) + [key] }
}

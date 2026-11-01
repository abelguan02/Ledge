import Foundation

enum AppIdentity {
    static let identifier = "local.ledge.desktop"
    static var name: String { displayName(languages: Locale.preferredLanguages) }
    static func displayName(languages: [String]) -> String {
        languages.first?.hasPrefix("zh") == true ? "搁这儿" : "Ledge"
    }
}

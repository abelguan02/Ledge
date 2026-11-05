import Foundation
import Combine

enum SkinChoice: String, CaseIterable, Sendable {
    case classic, unit01
    func title(language: String = Locale.preferredLanguages.first ?? "en") -> String {
        if language.hasPrefix("zh") {
            let traditional = language.contains("Hant") || language.contains("TW") || language.contains("HK")
            return self == .classic ? (traditional ? "經典" : "经典") : (traditional ? "初號機" : "初号机")
        }
        return self == .classic ? "Classic" : "Unit-01"
    }
}

@MainActor final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults?
    @Published var shortcut: AppShortcut? {
        didSet {
            defaults?.set(true, forKey: "shortcutConfigured")
            defaults?.set(shortcut.map { ["keyCode": $0.keyCode, "modifiers": $0.modifiers, "key": $0.key] as [String: Any] }, forKey: "shortcut")
        }
    }
    @Published var aiEnabled: Bool { didSet { defaults?.set(aiEnabled, forKey: "aiEnabled") } }
    @Published var automaticWebPreviews: Bool { didSet { defaults?.set(automaticWebPreviews, forKey: "automaticWebPreviews") } }
    @Published var language: LanguageChoice { didSet { defaults?.set(language.rawValue, forKey: "interfaceLanguage") } }
    private let preferredLanguages: [String]
    var interfaceLanguage: AppLanguage { language.resolve(preferredLanguages) }
    @Published var skin: SkinChoice { didSet { defaults?.set(skin.rawValue, forKey: "skin") } }
    @Published var dockEdge: DockEdge { didSet { defaults?.set(dockEdge.rawValue, forKey: "dockEdge") } }
    @Published var collectionLimit: Int64 { didSet { defaults?.set(collectionLimit, forKey: "collectionLimit") } }
    @Published var itemLimit: Int64 { didSet { defaults?.set(itemLimit, forKey: "itemLimit") } }
    @Published var freeDiskLimit: Int64 { didSet { defaults?.set(freeDiskLimit, forKey: "freeDiskLimit") } }
    init(defaults: UserDefaults? = nil, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.preferredLanguages = preferredLanguages
        self.defaults = defaults
        if defaults?.bool(forKey: "shortcutConfigured") == true {
            if let saved = defaults?.dictionary(forKey: "shortcut"), let code = saved["keyCode"] as? NSNumber,
               let modifiers = saved["modifiers"] as? NSNumber, let key = saved["key"] as? String {
                let candidate = AppShortcut(keyCode: code.uint32Value, modifiers: modifiers.uintValue, key: key)
                shortcut = candidate.valid ? candidate : nil
            } else { shortcut = nil }
        } else { shortcut = .initial }
        aiEnabled = defaults?.object(forKey: "aiEnabled") as? Bool ?? true
        automaticWebPreviews = defaults?.object(forKey: "automaticWebPreviews") as? Bool ?? true
        language = defaults?.string(forKey: "interfaceLanguage").flatMap(LanguageChoice.init(rawValue:)) ?? .initial(preferredLanguages)
        skin = SkinChoice(rawValue: defaults?.string(forKey: "skin") ?? "classic") ?? .classic
        dockEdge = DockEdge(rawValue: defaults?.string(forKey: "dockEdge") ?? "right") ?? .right
        collectionLimit = (defaults?.object(forKey: "collectionLimit") as? NSNumber)?.int64Value ?? 5_000_000_000
        itemLimit = (defaults?.object(forKey: "itemLimit") as? NSNumber)?.int64Value ?? 2_000_000_000
        freeDiskLimit = (defaults?.object(forKey: "freeDiskLimit") as? NSNumber)?.int64Value ?? 10_000_000_000
    }
    var capacity: CapacityLimits { CapacityLimits(collection: collectionLimit, item: itemLimit, freeDisk: freeDiskLimit) }
}

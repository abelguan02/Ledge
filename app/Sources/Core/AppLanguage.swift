import Foundation

enum LanguageChoice: String, CaseIterable, Sendable {
    case chinese, english

    static func initial(_ languages: [String] = Locale.preferredLanguages) -> Self {
        languages.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }
    func resolve(_ languages: [String] = Locale.preferredLanguages) -> AppLanguage {
        self == .english ? .english : AppLanguage(identifier: languages.first { $0.lowercased().hasPrefix("zh") } ?? "zh-Hans")
    }
}

enum AppLanguage: String, Sendable {
    case simplified = "zh-Hans", traditional = "zh-Hant", english = "en"

    init(identifier: String) {
        let id = identifier.lowercased()
        self = !id.hasPrefix("zh") ? .english : id.contains("hant") || id.contains("tw") || id.contains("hk") || id.contains("mo") ? .traditional : .simplified
    }
    var locale: Locale { Locale(identifier: rawValue) }
    private static let bundles = [Self.english, .traditional].reduce(into: [Self: Bundle]()) { result, language in
        if let url = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj") { result[language] = Bundle(url: url) }
    }
    func label(_ key: String) -> String {
        Self.bundles[self]?.localizedString(forKey: key, value: key, table: "Interface") ?? key
    }
    func phrase(_ key: String, _ values: CVarArg...) -> String {
        String(format: label(key), arguments: values)
    }
    func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .decimal, allowedUnits: .all, spellsOutZero: false).locale(locale))
    }
}

// Delay formatting until display. Values interpolated from a material, path or
// user name never become translation keys.
struct InterfaceText: ExpressibleByStringInterpolation, Codable, LocalizedError {
    let key: String
    let values: [Argument]
    var errorDescription: String? { rendered(.simplified) }
    indirect enum Argument: Codable, Sendable {
        case value(String), copy(InterfaceText), lines([InterfaceText]), bytes(Int64)
        func rendered(_ language: AppLanguage) -> String {
            switch self {
            case .bytes(let count): language.size(count)
            case .value(let text): text
            case .copy(let text): text.rendered(language)
            case .lines(let lines): lines.map { $0.rendered(language) }.joined(separator: "\n")
            }
        }
    }
    init(stringLiteral value: String) { self.init(key: value) }
    init(key: String) { self.key = key; values = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; values = stringInterpolation.values
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var values: [Argument] = []
        mutating func appendInterpolation(_ value: InterfaceText) { key += "%@"; values.append(.copy(value)) }
        mutating func appendInterpolation(bytes count: Int64) { key += "%@"; values.append(.bytes(count)) }
        mutating func appendInterpolation(lines values: [InterfaceText]) { key += "%@"; self.values.append(.lines(values)) }
        init(literalCapacity: Int, interpolationCount: Int) { }
        mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; values.append(.value(String(describing: value))) }
    }
    func rendered(_ language: AppLanguage) -> String {
        values.isEmpty ? language.label(key) : String(format: language.label(key), arguments: values.map { $0.rendered(language) })
    }
}

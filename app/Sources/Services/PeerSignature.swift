import Foundation
import Security

enum AIError: LocalizedError {
    case problem(String)
    var errorDescription: String? { if case let .problem(value) = self { value } else { nil } }
}

enum PeerSignature {
    // Bind each side to the actual signed peer embedded in this bundle. This
    // also supports ad-hoc development signing without trusting an ID alone.
    static func requirement(at url: URL, identifier: String) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw AIError.problem("后台签名无法验证，请重新构建应用。") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == identifier,
              let digest = values[kSecCodeInfoUnique as String] as? Data else { throw AIError.problem("后台身份不匹配。") }
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and cdhash H\"\(hash)\""
    }
}

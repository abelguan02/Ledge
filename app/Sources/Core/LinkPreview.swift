import Foundation

enum LinkPreviewState: String, Codable, Sendable { case pending, ready, failed, needsLogin, blocked }
struct LinkPreview: Codable, Equatable, Sendable {
    var state: LinkPreviewState
    var filename: String?
    var title: String?
    var siteName: String?
    var capturedAt: Date?
    var byteCount: Int64 = 0
}
enum LinkPreviewPolicy {
    static let oneTimeTerms = ["token", "auth", "login", "signin", "sign-in", "verify", "confirm", "activate", "unsubscribe", "reset", "password", "magic", "otp", "invite", "code", "session"]
    static func requiresConsent(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let names = [url.path] + (components?.queryItems?.map(\.name) ?? [])
        return names.contains { part in oneTimeTerms.contains { part.lowercased().contains($0) } }
    }
    static func initial(_ url: URL) -> LinkPreview { LinkPreview(state: requiresConsent(url) ? .blocked : .pending) }
}

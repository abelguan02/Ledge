import Foundation

private struct ReleaseVersion: Comparable {
    let parts: [Int]
    let display: String

    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count else { return nil }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
        display = text
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.parts == rhs.parts }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

@MainActor enum GitHubUpdates {
    typealias Fetch = (URLRequest) async throws -> (Data, Int)
    private enum Failure: Error { case response, version }
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    static func check(currentVersion: String, fetch: Fetch = fetchPublic) async throws -> UpdateCheck.Status {
        guard let installed = ReleaseVersion(currentVersion) else { throw Failure.version }
        let (data, status) = try await fetch(request(ProjectLinks.latestRelease))
        if status == 404 {
            // /latest also returns 404 for an absent/private repository. Confirm
            // the public releases endpoint exists before claiming no release.
            let (listing, listingStatus) = try await fetch(request(ProjectLinks.releases))
            guard listingStatus == 200 else { throw Failure.response }
            let releases = try JSONDecoder().decode([Release].self, from: listing)
            guard releases.allSatisfy({ $0.draft || $0.prerelease }) else { throw Failure.response }
            return .unreleased
        }
        guard status == 200 else { throw Failure.response }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { throw Failure.response }
        guard let latest = ReleaseVersion(release.tag_name) else { throw Failure.version }
        return latest > installed ? .available(latest.display, ProjectLinks.release(tag: release.tag_name)) : .current
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Ledge-UpdateCheck", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    private static func fetchPublic(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.response }
        return (data, http.statusCode)
    }
}

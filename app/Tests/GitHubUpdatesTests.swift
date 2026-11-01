import Foundation

@main struct GitHubUpdatesTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let result = try await GitHubUpdates.check(currentVersion: "0.1.0")
            print("Live public GitHub result: \(result)")
            return
        }
        precondition(ProjectLinks.repository.absoluteString == "https://github.com/abelguan02/Ledge")
        precondition(ProjectLinks.feedback.absoluteString == "https://github.com/abelguan02/Ledge/issues/new")
        func release(_ tag: String, preview: Bool = false) -> Data {
            try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": preview])
        }
        func check(_ installed: String, _ tag: String) async throws -> UpdateCheck.Status {
            try await GitHubUpdates.check(currentVersion: installed) { request in
                precondition(request.url == ProjectLinks.latestRelease)
                precondition(request.httpMethod == "GET" && request.httpBody == nil)
                precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
                precondition(request.value(forHTTPHeaderField: "Cookie") == nil && !request.httpShouldHandleCookies)
                precondition(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
                return (release(tag), 200)
            }
        }
        for (installed, latest) in [("0.9.0", "v0.10.0"), ("0.1.0", "0.1.1"), ("1.9.9", "2.0.0")] {
            let result = try await check(installed, latest)
            let display = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
            precondition(result == .available(display, URL(string: "https://github.com/abelguan02/Ledge/releases/tag/\(latest)")!))
        }
        for (installed, latest) in [("1.2.0", "v1.2"), ("2.0", "1.9.9"), ("1", "1.0.0")] {
            let result = try await check(installed, latest)
            precondition(result == .current)
        }
        for tag in ["", "v", "1..2", "1.2.3.4", "1.2-beta", "../other", String(repeating: "9", count: 80)] {
            do { _ = try await check("0.1.0", tag); fatalError("Invalid version accepted") } catch {}
        }
        for listing in [Data("[]".utf8), Data("[{\"tag_name\":\"v1.0-beta\",\"draft\":false,\"prerelease\":true}]".utf8)] {
            var calls = 0
            let result = try await GitHubUpdates.check(currentVersion: "0.1.0") { request in
                calls += 1
                if calls == 1 { return (Data(), 404) }
                precondition(calls == 2 && request.url == ProjectLinks.releases)
                return (listing, 200)
            }
            precondition(result == .unreleased && calls == 2)
        }
        for (data, status) in [(Data(), 403), (Data(), 429), (Data(), 500), (Data("broken".utf8), 200), (release("1.0", preview: true), 200)] {
            var calls = 0
            do {
                _ = try await GitHubUpdates.check(currentVersion: "0.1.0") { _ in calls += 1; return (data, status) }
                fatalError("Invalid response accepted")
            } catch { precondition(calls == 1) }
        }
        for (data, status) in [(Data(), 404), (Data(), 500), (Data("[{}]".utf8), 200), (Data("[{\"tag_name\":\"v1.0\",\"draft\":false,\"prerelease\":false}]".utf8), 200)] {
            var calls = 0
            do {
                _ = try await GitHubUpdates.check(currentVersion: "0.1.0") { _ in
                    calls += 1
                    return calls == 1 ? (Data(), 404) : (data, status)
                }
                fatalError("Missing repository or inconsistent release accepted")
            } catch { precondition(calls == 2) }
        }
        do {
            _ = try await GitHubUpdates.check(currentVersion: "0.1.0") { _ in throw URLError(.timedOut) }
            fatalError("Timeout accepted")
        } catch {}
        print("PASS: project links, numeric versions, release states, HTTP/JSON errors, privacy and timeout")
    }
}

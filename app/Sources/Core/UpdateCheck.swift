import Foundation
import Combine

@MainActor final class UpdateCheck: ObservableObject {
    enum Status: Equatable { case idle, checking, current, unreleased, available(String, URL), failed }
    @Published private(set) var status: Status = .idle
    private let query: () async throws -> Status
    private var generation = 0
    init(query: @escaping () async throws -> Status = {
        try await GitHubUpdates.check(currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }) { self.query = query }
    func check() async {
        guard status != .checking else { return }
        generation += 1; let current = generation
        status = .checking
        do { status = try await query() } catch { status = .failed }
        if status == .current || status == .unreleased {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if current == generation { status = .idle }
        }
    }
}

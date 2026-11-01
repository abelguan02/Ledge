import Foundation
import Combine

@MainActor final class UpdateCheck: ObservableObject {
    enum Status: Equatable { case idle, checking, current, available(String, URL), failed }
    @Published private(set) var status: Status = .idle
    private let query: () async throws -> Status
    private var generation = 0
    init(query: @escaping () async throws -> Status = { throw LibraryError.invalid("尚未设置发布地址") }) { self.query = query }
    func check() async {
        guard status != .checking else { return }
        generation += 1; let current = generation
        status = .checking
        do { status = try await query() } catch { status = .failed }
        if status == .current {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if current == generation { status = .idle }
        }
    }
}

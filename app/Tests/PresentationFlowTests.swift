import Foundation

@main @MainActor struct PresentationFlowTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--about") {
            let failure = UpdateCheck { throw URLError(.notConnectedToInternet) }
            precondition(failure.status == .idle)
            await failure.check()
            precondition(failure.status == .failed, "A failed query must never claim up to date")
            let url = URL(string: "https://example.invalid/releases/2")!
            var resume: CheckedContinuation<UpdateCheck.Status, Error>?
            let check = UpdateCheck { try await withCheckedThrowingContinuation { resume = $0 } }
            let task = Task { await check.check() }
            while resume == nil { await Task.yield() }
            precondition(check.status == .checking)
            await check.check()
            resume?.resume(returning: .available("2.0", url)); await task.value
            precondition(check.status == .available("2.0", url))
            let current = UpdateCheck { .current }
            let checking = Task { await current.check() }
            while current.status != .current { await Task.yield() }
            await checking.value
            precondition(current.status == .idle)
            var calls = 0
            let unreleased = UpdateCheck { calls += 1; return .unreleased }
            precondition(calls == 0, "Opening About must not query updates")
            let query = Task { await unreleased.check() }
            while unreleased.status != .unreleased { await Task.yield() }
            await query.value
            precondition(unreleased.status == .idle && calls == 1)
            print("PASS about: idle/checking/available/current/unreleased/reset/failure; no request before check; no network")
        } else {
            precondition(OnboardingSession.automaticallyPresent(eligible: true, seen: false, collectionCount: 1, materialCount: 0))
            for (eligible, seen, collections, materials) in [(false, false, 1, 0), (true, true, 1, 0), (true, false, 2, 0), (true, false, 1, 1)] {
                precondition(!OnboardingSession.automaticallyPresent(eligible: eligible, seen: seen, collectionCount: collections, materialCount: materials))
            }
            let session = OnboardingSession()
            session.hoveredEdge(); session.dropped()
            precondition(!session.edgeCompleted && !session.dropCompleted)
            session.next(); session.next()
            precondition(session.step == .edge && !session.canContinue)
            session.hoveredEdge(); session.next(); session.next()
            precondition(session.step == .drop && !session.canContinue)
            session.dropped(); session.next()
            precondition(session.step == .paste)
            session.next(); session.next(); session.next()
            precondition(session.finished && !session.edgeCompleted && !session.dropCompleted && !session.canContinue)
            for step in OnboardingSession.Step.allCases {
                let skipped = OnboardingSession()
                while skipped.step != step { skipped.hoveredEdge(); skipped.dropped(); skipped.next() }
                skipped.finish(); skipped.next()
                precondition(skipped.finished && skipped.step == step && !skipped.edgeCompleted && !skipped.dropCompleted)
            }
            print("PASS onboarding: new-only eligibility, six steps, physical hover/drop gates, completion/skip cleanup; no library/clipboard/network dependency")
        }
    }
}

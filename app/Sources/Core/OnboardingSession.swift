import Foundation
import Combine

@MainActor final class OnboardingSession: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, edge, drop, paste, export, shortcut }
    @Published private(set) var step: Step = .welcome
    @Published private(set) var edgeCompleted = false
    @Published private(set) var dropCompleted = false
    @Published private(set) var finished = false
    var canContinue: Bool { !finished && (step != .edge || edgeCompleted) && (step != .drop || dropCompleted) }
    func hoveredEdge() { if step == .edge { edgeCompleted = true } }
    func dropped() { if step == .drop { dropCompleted = true } }
    func next() {
        guard canContinue else { return }
        if let next = Step(rawValue: step.rawValue + 1) { step = next } else { finish() }
    }
    func finish() { finished = true; edgeCompleted = false; dropCompleted = false }
    static func automaticallyPresent(eligible: Bool, seen: Bool, collectionCount: Int, materialCount: Int) -> Bool {
        eligible && !seen && collectionCount == 1 && materialCount == 0
    }
}

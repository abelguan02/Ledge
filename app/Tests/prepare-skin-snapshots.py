"""Copy production sources and append file-local fixture access, without changing rendering code."""
import pathlib
import shutil
import sys

source, destination = map(pathlib.Path, sys.argv[1:3])
shutil.copytree(source, destination)
(destination / "UI/Application.swift").unlink()  # The fixture supplies @main.
adapters = {
    "WorkbenchView.swift": r'''
// Expose the production artwork beneath the transparent native drag surface.
// ImageRenderer otherwise substitutes a yellow unsupported-AppKit placeholder.
extension MaterialView { var snapshotArtwork: some View { content } }
extension WorkbenchView { var snapshotHeader: some View { header } }
''',
    "AboutWindow.swift": r'''
extension AboutView {
    static func snapshot(coffee: Bool) -> Self {
        var view = Self(update: UpdateCheck(), replay: {})
        view._coffee = AboutState(initialValue: coffee)
        return view
    }
}
@MainActor func skinSnapshotAbout(coffee: Bool) -> some View { AboutView.snapshot(coffee: coffee) }
''',
    "SettingsWindow.swift": r'''
extension SettingsView {
    static func snapshot(model: WorkbenchModel, tab: Int) -> Self {
        var view = Self(model: model, preferences: model.preferences,
                        shortcut: GlobalShortcut(preferences: model.preferences, registry: SnapshotShortcuts()),
                        login: LoginPreference(), resize: { _, _ in })
        view._tab = SettingsState(initialValue: SettingsTab.allCases[tab])
        return view
    }
}
@MainActor func skinSnapshotSettings(model: WorkbenchModel, tab: Int) -> some View { SettingsView.snapshot(model: model, tab: tab) }
''',
    "OnboardingWindow.swift": r'''
extension OnboardingView {
    static func snapshot(preferences: AppPreferences, step: Int) -> Self {
        let session = OnboardingSession()
        for _ in 0..<step { session.hoveredEdge(); session.dropped(); session.next() }
        var view = Self(session: session, preferences: preferences, finish: {})
        view._phase = GuideState(initialValue: 20)
        return view
    }
}
@MainActor func skinSnapshotGuide(preferences: AppPreferences, step: Int) -> some View {
    OnboardingView.snapshot(preferences: preferences, step: step)
}
''',
}
if "--payment-methods" in sys.argv[3:]:
    adapters["AboutWindow.swift"] += r'''
@MainActor func skinSnapshotCoffee(method: CoffeePaymentMethod) -> some View {
    AboutView.snapshot(method: method)
}
private extension AboutView {
    static func snapshot(method: CoffeePaymentMethod) -> Self {
        var view = snapshot(coffee: true)
        view._paymentMethod = AboutState(initialValue: method)
        return view
    }
}
'''
for name, adapter in adapters.items():
    path = destination / "UI" / name
    with path.open("a") as output:
        output.write(adapter)

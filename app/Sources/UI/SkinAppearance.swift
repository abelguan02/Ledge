import SwiftUI
import AppKit

extension LedgeSkin {
    static func selected(_ choice: SkinChoice) -> LedgeSkin { choice == .classic ? .classic : .unit01 }
}

// Stable view identity: only environment values change. In particular this does
// not replace an NSHostingView, CanvasScrollView, editor, or popover coordinator.
struct SkinRoot<Content: View>: View {
    @ObservedObject var preferences: AppPreferences
    @Environment(\.colorScheme) private var systemScheme
    let content: Content
    var scanlines: Bool
    var decorateWindow: Bool
    init(preferences: AppPreferences, scanlines: Bool = true, decorateWindow: Bool = true, @ViewBuilder content: () -> Content) {
        self.preferences = preferences; self.scanlines = scanlines; self.decorateWindow = decorateWindow; self.content = content()
    }
    var body: some View {
        let skin = LedgeSkin.selected(preferences.skin)
        content
            .background { if decorateWindow { SkinWindowChrome(isUnit: skin.isUnit).frame(width: 0, height: 0) } }
            .foregroundStyle(skin.ink.primary)
            .tint(skin.palette.accent)
            .overlay { if scanlines && skin.isUnit { SkinScanlines() } }
            .environment(\.ledgeSkin, LedgeSkin.selected(preferences.skin))
            .environment(\.colorScheme, preferences.skin == .unit01 ? .dark : systemScheme)
    }
}

// Change only our own hosting window's shadow, leaving system preview panels,
// file choosers, permission dialogs and menus outside the skin environment.
private struct SkinWindowChrome: NSViewRepresentable {
    let isUnit: Bool
    func makeNSView(context: Context) -> SkinChromeView { SkinChromeView() }
    func updateNSView(_ view: SkinChromeView, context: Context) { view.isUnit = isUnit; view.apply() }
    static func dismantleNSView(_ view: SkinChromeView, coordinator: ()) { view.restore() }
}

private final class SkinChromeView: NSView {
    var isUnit = false
    private weak var styledWindow: NSWindow?
    private var originalShadow = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restore()
        styledWindow = window
        originalShadow = window?.hasShadow ?? false
        apply()
    }
    func apply() {
        let shadow = isUnit ? false : originalShadow
        if styledWindow?.hasShadow != shadow { styledWindow?.hasShadow = shadow }
    }
    func restore() { styledWindow?.hasShadow = originalShadow; styledWindow = nil }
}

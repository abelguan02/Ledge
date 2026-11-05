import AppKit
import SwiftUI

// Bounds that must remain optically clear beneath a root scanline overlay.
struct SkinScanlineExclusion: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// Presentation values only. A skin never owns material, selection, viewport,
// undo, or processing state.
struct LedgeSkin: Sendable {
    static let classic = LedgeSkin()
    static let unit01 = LedgeSkin(isUnit: true)
    var isUnit = false
    var typography: Typography { Typography(isUnit: isUnit) }
    var materials: Materials { Materials(isUnit: isUnit) }
    var palette: Palette { Palette(isUnit: isUnit) }
    var ink: Ink { Ink(isUnit: isUnit) }
    var shapes: Shapes { Shapes(isUnit: isUnit) }
    var motion: Motion { Motion(isUnit: isUnit) }
    let opacity = Opacity()
    var shadows: Shadows { Shadows(isUnit: isUnit) }

    struct Opacity: Sendable {
        let disabled = 0.35
        let unselected = 0.4
    }

    struct Shadow: Sendable {
        let color: Color
        let radius: CGFloat
        var x: CGFloat = 0
        var y: CGFloat = 0
    }

    struct Shadows: Sendable {
        var isUnit = false
        let resizeBlur = 2.0
        var tab: Shadow { Shadow(color: isUnit ? .clear : .black.opacity(0.18), radius: 4, x: -1) }
        var actionBar: Shadow { Shadow(color: isUnit ? .clear : .black.opacity(0.15), radius: 14, y: 6) }
        var tray: Shadow { Shadow(color: isUnit ? .clear : .black.opacity(0.25), radius: 18, y: 8) }
        var answer: Shadow { Shadow(color: isUnit ? .clear : .black.opacity(0.2), radius: 18, y: 10) }
        var appIcon: Shadow { Shadow(color: isUnit ? .clear : .black.opacity(0.25), radius: 8, y: 3) }
        var sample: Shadow { Shadow(color: isUnit ? .clear : .black.opacity(0.3), radius: 12, y: 6) }
        var cursor: Shadow { Shadow(color: isUnit ? .clear : .black, radius: 2) }
        func card(dark: Bool) -> Shadow { Shadow(color: isUnit ? .clear : .black.opacity(dark ? 0.25 : 0.1), radius: 9, y: 5) }
        func guideGlow(_ glowing: Bool) -> Shadow { Shadow(color: isUnit ? .clear : .white.opacity(glowing ? 0.7 : 0), radius: 18) }
        func key(pressed: Bool) -> Shadow { Shadow(color: isUnit ? .clear : .black.opacity(0.35), radius: 0, y: pressed ? 1 : 4) }
        func panel(dark: Bool, x: CGFloat, y: CGFloat) -> Shadow {
            Shadow(color: isUnit ? .clear : .black.opacity(dark ? 0.3 : 0.12), radius: 14, x: x, y: y)
        }
    }

    struct Motion: Sendable {
        var isUnit = false
        var hover: Animation { .easeOut(duration: 0.15) }
        func guideSpring(reduced: Bool) -> Animation {
            reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.75)
        }
        func guideEase(reduced: Bool) -> Animation {
            reduced ? .easeInOut(duration: 0.2) : .timingCurve(0.25, 0.8, 0.25, 1, duration: 0.35)
        }
        func dropGlow(reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.2 : 0.6) }
        var cursor: Animation { .easeInOut(duration: 0.8) }
        var keyDown: Animation { .easeIn(duration: 0.08) }
        var keyUp: Animation { .easeOut(duration: 0.12) }
        var glow: Animation { .easeOut(duration: 0.6) }
        var export: Animation { .easeInOut(duration: 1) }
        var exit: Animation { .easeOut(duration: 0.2) }
        let letterDelay: Duration = .milliseconds(80)
        let welcomeDelay: Duration = .milliseconds(650)
        let cursorDelay: Duration = .milliseconds(400)
        let cursorHold: Duration = .milliseconds(1300)
        let cursorRepeat: Duration = .milliseconds(2300)
        let keyHold: Duration = .milliseconds(80)
        let keyGap: Duration = .milliseconds(55)
        let glowDelay: Duration = .milliseconds(350)
        let exportDelay: Duration = .milliseconds(400)
        let exportLift: Duration = .milliseconds(150)
        let exportTravel: Duration = .seconds(1)
        let exitDelay: Duration = .milliseconds(200)
        let edgeFrameInterval = 1.0 / 30
        func tabPulse(time: TimeInterval, reduced: Bool) -> Double {
            reduced ? 1 : 0.775 - 0.225 * cos(time * 2 * Double.pi / 2.4)
        }
        func tabFlow(time: TimeInterval) -> Double { -14 + time.truncatingRemainder(dividingBy: 1.6) / 1.6 * 54 }
        func animateSettingsResize(reduced: Bool) -> Bool { !reduced }
    }

    // Keep hierarchical text styles distinct from Color.primary/secondary.
    // Flattening them to fixed RGB values changes vibrancy and disabled text.
    struct Ink: Sendable {
        var isUnit = false
        private var palette: Palette { Palette(isUnit: isUnit) }
        var primary: AnyShapeStyle { isUnit ? AnyShapeStyle(palette.primary) : AnyShapeStyle(HierarchicalShapeStyle.primary) }
        var secondary: AnyShapeStyle { isUnit ? AnyShapeStyle(palette.secondary) : AnyShapeStyle(HierarchicalShapeStyle.secondary) }
        var quaternary: AnyShapeStyle { isUnit ? AnyShapeStyle(palette.secondary.opacity(0.4)) : AnyShapeStyle(HierarchicalShapeStyle.quaternary) }
        var background: AnyShapeStyle { isUnit ? AnyShapeStyle(palette.base) : AnyShapeStyle(BackgroundStyle()) }
        private func layer(_ opacity: Double, unit: Color) -> AnyShapeStyle {
            isUnit ? AnyShapeStyle(unit) : AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(opacity))
        }
        var clearCategories: AnyShapeStyle { layer(0.05, unit: palette.inset) }
        var sectionInset: AnyShapeStyle { layer(0.06, unit: palette.inset) }
        var headerControl: AnyShapeStyle { layer(0.08, unit: palette.inset) }
        var floatingBorder: AnyShapeStyle { layer(0.12, unit: palette.line) }
        var answerConnector: AnyShapeStyle { layer(0.4, unit: palette.line) }
        var dragOutline: AnyShapeStyle { layer(0.45, unit: palette.accent) }
        func dropFill(active: Bool) -> AnyShapeStyle { layer(active ? 0.12 : 0.03, unit: active ? palette.accent.opacity(0.1) : palette.base) }
        func dropBorder(active: Bool) -> AnyShapeStyle { layer(active ? 0.6 : 0.1, unit: active ? palette.accent : palette.line) }
    }

    struct Palette: Sendable {
        var isUnit = false
        var base: Color { Self.rgb(0x07060C) }
        var inset: Color { Self.rgb(0x0D0A16) }
        var armor: Color { Self.rgb(0x4A2A9E) }
        var line: Color { Self.rgb(0x6B3FC4) }
        var separator: Color { Self.rgb(0x2E2550) }
        var warning: Color { Self.rgb(0xFF7A1A) }
        var alarm: Color { Self.rgb(0xC8101E) }
        static func rgb(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
        }
        var placeholderLow: Color { light.opacity(0.04) }
        var darkSettingsGroup: Color { isUnit ? inset : light.opacity(0.06) }
        var insetLight: Color { light.opacity(0.08) }
        var stackRear: Color { isUnit ? line.opacity(0.5) : light.opacity(0.10) }
        var tabBorderBottom: Color { isUnit ? line : light.opacity(0.12) }
        var controlBorder: Color { isUnit ? line : light.opacity(0.14) }
        var stackFront: Color { isUnit ? line : light.opacity(0.16) }
        var trayBorder: Color { isUnit ? line : light.opacity(0.18) }
        var tabBorderTop: Color { isUnit ? line : light.opacity(0.22) }
        var stackHalo: Color { isUnit ? accent.opacity(0.3) : light.opacity(0.24) }
        var stackBorder: Color { isUnit ? line : light.opacity(0.28) }
        var keyBorder: Color { isUnit ? line : light.opacity(0.3) }
        var tabBusy: Color { isUnit ? accent.opacity(0.35) : light.opacity(0.4) }
        var checkboxBorder: Color { isUnit ? line : light.opacity(0.45) }
        var previewProgress: Color { light.opacity(0.5) }
        var linkSecondary: Color { isUnit ? secondary : light.opacity(0.6) }
        var guideSkip: Color { isUnit ? secondary : light.opacity(0.65) }
        var guideDetail: Color { isUnit ? secondary : light.opacity(0.7) }
        var lightSettingsGroup: Color { isUnit ? inset : light.opacity(0.75) }
        var pendingBorder: Color { light.opacity(0.85) }
        var tabQuiet: Color { isUnit ? accent : light.opacity(0.88) }
        var linkAction: Color { light.opacity(0.9) }
        var lightCollection: Color { isUnit ? inset : light.opacity(0.94) }
        var linkText: Color { isUnit ? primary : light.opacity(0.95) }
        var lightInset: Color { shade.opacity(0.05) }
        var lightCurrentBadge: Color { shade.opacity(0.07) }
        var lightPanelBorder: Color { isUnit ? line : shade.opacity(0.08) }
        var busyScrim: Color { shade.opacity(0.35) }
        var clearDim: Color { shade.opacity(0.5) }
        var paymentMissingText: Color { shade.opacity(0.65) }
        var feedbackBackdrop: Color { shade.opacity(0.8) }
        var gridDot: Color { isUnit ? line : primary.opacity(0.14) }
        var marquee: Color { accent.opacity(0.1) }
        func collectionDestructive(dark: Bool) -> Color { destructive.opacity(dark ? 0.18 : 0.12) }
        func panelTint(dark: Bool) -> Color { isUnit ? base : (dark ? shade : light).opacity(0.12) }
        func aboutTint(dark: Bool) -> Color { isUnit ? base : (dark ? aboutDark : aboutLight).opacity(dark ? 0.78 : 0.86) }
        func guideRing(glowing: Bool) -> Color { light.opacity(glowing ? 0 : 0.7) }
        var light: Color { .white }
        var shade: Color { .black }
        var clear: Color { .clear }
        var primary: Color { isUnit ? Self.rgb(0xEDE8DE) : .primary }
        var secondary: Color { isUnit ? Self.rgb(0xA79FC0) : .secondary }
        var accent: Color { isUnit ? Self.rgb(0x9BE34E) : .accentColor }
        var destructive: Color { isUnit ? Self.rgb(0xFF4655) : .red }
        var connected: Color { isUnit ? accent : .green }
        var inactive: Color { isUnit ? secondary : .gray }
        var feedback: Color { isUnit ? accent : .blue }
        var coffee: Color { isUnit ? armor : .orange }
        var settingsDark: Color { isUnit ? base : Color(nsColor: .windowBackgroundColor) }
        var settingsTab: Color { isUnit ? inset : primary.opacity(0.06) }
        var settingsLight: Color { isUnit ? base : Color(red: 236/255, green: 236/255, blue: 238/255) }
        var aboutDark: Color { isUnit ? base : Color(red: 30/255, green: 30/255, blue: 36/255) }
        var aboutLight: Color { isUnit ? base : Color(red: 248/255, green: 248/255, blue: 250/255) }
        var repositoryIcon: Color { isUnit ? armor : Color(red: 36/255, green: 41/255, blue: 47/255) }
        var tab: Color { isUnit ? armor : Color(red: 44 / 255, green: 44 / 255, blue: 50 / 255).opacity(0.62) }
        var tabError: Color { isUnit ? destructive : Color(red: 1, green: 69 / 255, blue: 58 / 255) }
        var collectionDim: Color { Color(red: 10/255, green: 10/255, blue: 14/255).opacity(0.18) }
        var trayDim: Color { Color(red: 10/255, green: 10/255, blue: 14/255).opacity(0.25) }
        var collectionDark: Color { isUnit ? inset : Color(red: 48/255, green: 48/255, blue: 54/255).opacity(0.9) }
        var collectionFade: Color { isUnit ? inset : Color(white: 0.19) }
        var uncheckedBorder: Color { isUnit ? line : Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.4) }
        var stackBadge: Color { isUnit ? armor : Color(red: 60/255, green: 60/255, blue: 66/255).opacity(0.88) }
        var link: Color { isUnit ? inset : Color(red: 58/255, green: 58/255, blue: 62/255).opacity(0.88) }
        var noteText: Color { isUnit ? primary : Color(white: 0.15) }
        var noteDark: Color { isUnit ? base : Color(red: 0.984, green: 0.98, blue: 0.965) }
        var noteLight: Color { isUnit ? base : Color(red: 1, green: 0.992, blue: 0.965) }
        var guideDim: Color { isUnit ? base : Color(red: 8/255, green: 8/255, blue: 14/255).opacity(0.62) }
        var sampleSkyTop: Color { Color(red: 1, green: 0.7, blue: 0.48) }
        var sampleSkyMiddle: Color { Color(red: 1, green: 0.43, blue: 0.57) }
        var sampleSkyBottom: Color { Color(red: 0.48, green: 0.36, blue: 1) }
        var sampleSun: Color { Color(red: 1, green: 0.94, blue: 0.79) }
        var sampleMountain: Color { Color(red: 0.17, green: 0.12, blue: 0.36).opacity(0.5) }
        var sampleNote: Color { Color(red: 1, green: 0.85, blue: 0.35) }
        var nativeControl: NSColor { isUnit ? NSColor(inset) : .controlBackgroundColor }
        var nativeAccent: NSColor { isUnit ? NSColor(accent) : .controlAccentColor }
        var nativeSeparator: NSColor { isUnit ? NSColor(separator) : .separatorColor }
        var nativeLabel: NSColor { isUnit ? NSColor(primary) : .labelColor }
        var nativeSecondary: NSColor { isUnit ? NSColor(secondary) : .secondaryLabelColor }
        var resizeHandle: NSColor { .white }
        var resizeShadow: NSColor { isUnit ? .clear : .black.withAlphaComponent(0.3) }
    }

    struct Shapes: Sendable {
        var isUnit = false
        var checkbox: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 4) }
        var badge: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 5) }
        var smallControl: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 6) }
        var compactControl: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 7) }
        var control: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 8) }
        var trayItem: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 9) }
        var field: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 10) }
        var card: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 12) }
        var payment: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 14) }
        var dropZone: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 16) }
        var floatingCard: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 18) }
        var dialog: RoundedRectangle { RoundedRectangle(cornerRadius: isUnit ? 0 : 22) }
        var capsule: SkinContour { SkinContour(rectangular: isUnit, circular: false) }
        var circle: SkinContour { SkinContour(rectangular: isUnit, circular: true) }
        var shortcutRadius: CGFloat { isUnit ? 0 : 6 }
    }

    struct Typography: Sendable {
        var isUnit = false
        var micro: Font { .system(size: 9) }
        var disclosure: Font { .system(size: 9, weight: .bold) }
        var tiny: Font { .system(size: 10) }
        var checkmark: Font { .system(size: 10, weight: .bold) }
        var mediaTime: Font { .system(size: 10, design: .monospaced) }
        var badge: Font { .system(size: 10.5) }
        var linkAddress: Font { .system(size: 10.5, weight: .medium, design: .monospaced) }
        var small: Font { isUnit ? .system(size: 11, weight: .semibold) : .system(size: 11) }
        var measurement: Font { .system(size: 11, design: .monospaced) }
        var detail: Font { isUnit ? .system(size: 11.5, weight: .semibold) : .system(size: 11.5) }
        var caption: Font { isUnit ? .system(size: 12, weight: .semibold) : .system(size: 12) }
        var captionMedium: Font { .system(size: 12, weight: .medium) }
        var captionStrong: Font { .system(size: 12, weight: .semibold) }
        var note: Font { isUnit ? .system(size: 12.5, weight: .semibold) : .system(size: 12.5) }
        var cardTitle: Font { .system(size: 12.5, weight: .semibold) }
        var body: Font { isUnit ? .system(size: 13, weight: .semibold) : .system(size: 13) }
        var bodyStrong: Font { .system(size: 13, weight: .semibold) }
        var answer: Font { isUnit ? .system(size: 13.5, weight: .semibold) : .system(size: 13.5) }
        var actionIcon: Font { .system(size: 14) }
        var collectionTitle: Font { .system(size: 15, weight: .semibold) }
        var answerTitle: Font { .system(size: 17, weight: .bold) }
        var sampleNote: Font { .system(size: 18, weight: .medium) }
        var sectionTitle: Font { .system(size: 18, weight: .semibold) }
        var confirmationTitle: Font { .system(size: 19, weight: .semibold) }
        var settingsIcon: Font { .system(size: 20) }
        var linkPlaceholder: Font { .system(size: 22, weight: .regular) }
        var cursor: Font { .system(size: 24) }
        var applicationTitle: Font { .system(size: 24, weight: .bold) }
        var onboardingTitle: Font { .system(size: 26, weight: .bold) }
        var mediaIcon: Font { .system(size: 28) }
        var playIcon: Font { .system(size: 30) }
        var keyCap: Font { .system(size: 30, weight: .medium) }
        var sampleFile: Font { .system(size: 64) }
        var headline: Font { .headline }
        var systemCaption: Font { .caption }
        var titleIcon: Font { .title2 }
        var emphasis: Font.Weight { .semibold }
        func dropLabel(primary: Bool) -> Font { .system(size: primary ? 19 : 13, weight: .medium) }
        // Text measurement must use the same font as the rendered note.
        var measuredNote: NSFont { .systemFont(ofSize: 12.5, weight: isUnit ? .semibold : .regular) }
        var shortcut: NSFont { .systemFont(ofSize: 11.5) }
        var shortcutClear: NSFont { .systemFont(ofSize: 13) }
    }

    struct Materials: Sendable {
        var isUnit = false
        var regular: AnyShapeStyle { isUnit ? AnyShapeStyle(Palette(isUnit: true).inset) : AnyShapeStyle(SwiftUI.Material.regular) }
        var ultraThin: AnyShapeStyle { isUnit ? AnyShapeStyle(Palette(isUnit: true).inset) : AnyShapeStyle(SwiftUI.Material.ultraThin) }
        var glass: NSVisualEffectView.Material { .hudWindow }
        var blending: NSVisualEffectView.BlendingMode { .behindWindow }
        var state: NSVisualEffectView.State { .active }
        var tabAppearance: NSAppearance.Name { .darkAqua }
    }
}

private struct LedgeSkinKey: EnvironmentKey {
    static let defaultValue = LedgeSkin.classic
}

extension EnvironmentValues {
    var ledgeSkin: LedgeSkin {
        get { self[LedgeSkinKey.self] }
        set { self[LedgeSkinKey.self] = newValue }
    }
}

extension View {
    func skinShadow(_ value: LedgeSkin.Shadow) -> some View {
        shadow(color: value.color, radius: value.radius, x: value.x, y: value.y)
    }
}

// Keeps the exact classic Capsule/Circle paths while giving the second skin
// rectangular controls, including inset strokes.
struct SkinContour: InsettableShape {
    var rectangular: Bool
    var circular: Bool
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        if rectangular { return Rectangle().inset(by: inset).path(in: rect) }
        if circular { return Circle().inset(by: inset).path(in: rect) }
        return Capsule().inset(by: inset).path(in: rect)
    }
    func inset(by amount: CGFloat) -> SkinContour {
        var shape = self; shape.inset += amount; return shape
    }
}

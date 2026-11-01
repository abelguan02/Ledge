import AppKit
import ApplicationServices
import CoreGraphics
import Carbon

// Explicitly invoked QA utility. Targets only the supplied app PID / coordinates.
let args = CommandLine.arguments
func point(_ i: Int) -> CGPoint { CGPoint(x: Double(args[i])!, y: Double(args[i+1])!) }
func mouse(_ type: CGEventType, at location: CGPoint, delta: CGPoint = .zero, clickCount: Int64 = 1) {
    let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: location, mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left)
    event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
    var flags: CGEventFlags = []
    if args.contains("--shift") { flags.insert(.maskShift) }
    if args.contains("--cmd") { flags.insert(.maskCommand) }
    if args.contains("--option") { flags.insert(.maskAlternate) }
    event?.flags = flags
    event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
    event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
    event?.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
    event?.post(tap: .cghidEventTap)
}
func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &result) == .success ? result : nil
}
func findElement(_ root: AXUIElement, label: String, role: String? = nil) -> AXUIElement? {
    let candidateRole = axValue(root, kAXRoleAttribute as CFString) as? String
    let actionable = args[1] != "tap" || role != nil || ["AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(candidateRole ?? "")
    if actionable, (role == nil || role == candidateRole), [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: { axValue(root, $0 as CFString) as? String == label }) { return root }
    // Never enumerate a native file browser or Finder sidebar for control lookup.
    if candidateRole == "AXBrowser" || candidateRole == "AXOutline" { return nil }
    for child in axValue(root, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
        if let found = findElement(child, label: label, role: role) { return found }
    }
    return nil
}
func waitElement(_ root: AXUIElement, label: String, role: String? = nil) -> AXUIElement {
    for _ in 0..<30 {
        if let found = findElement(root, label: label, role: role) { return found }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fputs("Control not found: \(label)\n", stderr); exit(2)
}
func editableElement(_ root: AXUIElement) -> AXUIElement? {
    if let role = axValue(root, kAXRoleAttribute as CFString) as? String, ["AXTextArea", "AXTextField"].contains(role) { return root }
    for child in axValue(root, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
        if let value = editableElement(child) { return value }
    }
    return nil
}
func firstSheet(_ root: AXUIElement) -> AXUIElement? {
    if axValue(root, kAXRoleAttribute as CFString) as? String == "AXSheet" { return root }
    for child in axValue(root, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
        if let sheet = firstSheet(child) { return sheet }
    }
    return nil
}
switch args[1] {
case "focus":
    let app = AXUIElementCreateApplication(pid_t(args[2])!)
    print("frontmost=\(String(describing: axValue(app, kAXFrontmostAttribute as CFString)))")
    for attribute in [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute] {
        if let value = axValue(app, attribute as CFString) {
            let element = value as! AXUIElement
            print("\(attribute): role=\(String(describing: axValue(element, kAXRoleAttribute as CFString))) description=\(String(describing: axValue(element, kAXDescriptionAttribute as CFString)))")
        }
    }
case "hit":
    var target: AXUIElement?
    let p = point(3)
    let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &target)
    var pid: pid_t = 0
    if let target { AXUIElementGetPid(target, &pid) }
    print("hit=\(result.rawValue) expectedApp=\(pid == pid_t(args[2])!)")
case "eventcheck":
    print("secureEventInput=\(IsSecureEventInputEnabled())")
    print("AX=\(AXIsProcessTrusted()) posting=\(CGPreflightPostEventAccess()) buttons=\(NSEvent.pressedMouseButtons) combinedLeft=\(CGEventSource.buttonState(.combinedSessionState, button: .left)) cursor=\(String(describing: CGEvent(source: nil)?.location)) screens=\(NSScreen.screens.map(\.frame))")
case "pid":
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.dump.desktop").first { print(running.processIdentifier) } else { exit(2) }
case "tap", "menu", "type", "type-first", "value", "rect":
    let pid = pid_t(args[2])!, app = AXUIElementCreateApplication(pid)
    if args[1] == "menu" {
        let menu = waitElement(app, label: "Dump", role: "AXMenuBarItem")
        AXUIElementPerformAction(menu, kAXPressAction as CFString)
    }
    let role = args[1] == "menu" ? "AXMenuItem" : (args.count > 4 && ["value", "tap"].contains(args[1]) ? args[4] : nil)
    let target = args[1] == "type-first" ? (firstSheet(app) ?? app) : waitElement(app, label: args[3], role: role)
    if args[1] == "type" || args[1] == "type-first" {
        guard let field = editableElement(target) else { fputs("No editable control\n", stderr); exit(3) }
        let activation = Process(); activation.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activation.arguments = ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"]
        try activation.run(); activation.waitUntilExit()
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { fputs("Cannot focus field\n", stderr); exit(3) }
        Thread.sleep(forTimeInterval: 0.15)
        let units = Array(args[4].utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.2)
        print(axValue(field, kAXValueAttribute as CFString) as? String ?? "")
    } else if args[1] == "rect" {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = axValue(target, kAXPositionAttribute as CFString) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = axValue(target, kAXSizeAttribute as CFString) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        print("\(p.x),\(p.y),\(s.width),\(s.height)")
    } else if args[1] == "value" {
        if let value = axValue(target, kAXValueAttribute as CFString) { print(value) }
    } else {
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success else { fputs("AXPress failed: \(result.rawValue)\n", stderr); exit(3) }
    }
case "press", "inspect":
    var element = AXUIElementCreateApplication(pid_t(args[2])!)
    for part in args[3].split(separator: ".") {
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        element = (children as! [AXUIElement])[Int(part)!]
    }
    if args[1] == "inspect" {
        for attribute in [kAXRoleAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXHelpAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute] {
            if let value = axValue(element, attribute as CFString) { print("\(attribute)=\(value)") }
        }
    } else { print(AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue) }
case "windows":
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    let own = rows.filter { args.count > 2 ? ($0[kCGWindowOwnerPID as String] as? Int == Int(args[2])) : ($0[kCGWindowOwnerName as String] as? String == "Dump") }
    print(String(data: try JSONSerialization.data(withJSONObject: own), encoding: .utf8)!)
case "move":
    mouse(.mouseMoved, at: point(2))
case "click", "rightclick", "doubleclick":
    let location = point(2)
    mouse(.mouseMoved, at: location)
    Thread.sleep(forTimeInterval: 0.15)
    mouse(args[1] == "rightclick" ? .rightMouseDown : .leftMouseDown, at: location)
    Thread.sleep(forTimeInterval: 0.1)
    mouse(args[1] == "rightclick" ? .rightMouseUp : .leftMouseUp, at: location)
    if args[1] == "doubleclick" {
        Thread.sleep(forTimeInterval: 0.08)
        mouse(.leftMouseDown, at: location, clickCount: 2)
        mouse(.leftMouseUp, at: location, clickCount: 2)
    }
case "drag", "dragvia", "pan":
    let from = point(2), to = point(4)
    let panning = args[1] == "pan"
    if panning { CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)?.post(tap: .cghidEventTap) }
    defer { if panning { CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap) } }
    let board = NSPasteboard(name: .drag), before = NSPasteboard(name: .drag).changeCount
    mouse(.mouseMoved, at: from)
    Thread.sleep(forTimeInterval: 0.15)
    mouse(.leftMouseDown, at: from)
    Thread.sleep(forTimeInterval: 0.2)
    for n in 1...40 {
        let t = Double(n)/40
        let p = CGPoint(x: from.x + (to.x-from.x)*t, y: from.y + (to.y-from.y)*t)
        mouse(.leftMouseDragged, at: p, delta: CGPoint(x: (to.x-from.x)/40, y: (to.y-from.y)/40))
        Thread.sleep(forTimeInterval: 0.05)
    }
    var release = to
    if args[1] == "dragvia" {
        Thread.sleep(forTimeInterval: 0.5)
        release = point(6)
        for n in 1...20 {
            let t = Double(n)/20
            mouse(.leftMouseDragged, at: CGPoint(x: to.x+(release.x-to.x)*t, y: to.y+(release.y-to.y)*t), delta: CGPoint(x: (release.x-to.x)/20, y: (release.y-to.y)/20))
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    Thread.sleep(forTimeInterval: args[1] == "drag" && args.count > 6 ? (Double(args[6]) ?? 0.4) : 0.4)
    if args.contains("--escape") {
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap) }
        Thread.sleep(forTimeInterval: 0.2)
    }
    if panning { print("Pan completed") }
    else { print("Drag pasteboard changed: \(board.changeCount != before); types: \((board.types ?? []).map(\.rawValue))") }
    mouse(.leftMouseUp, at: release)
case "key":
    let code = CGKeyCode(args[2])!
    var flags: CGEventFlags = []
    if args.count > 3 {
        if args[3].contains("cmd") { flags.insert(.maskCommand) }
        if args[3].contains("ctrl") { flags.insert(.maskControl) }
        if args[3].contains("opt") { flags.insert(.maskAlternate) }
        if args[3].contains("shift") { flags.insert(.maskShift) }
    }
    for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); e?.flags = flags; e?.post(tap: .cghidEventTap) }
case "keypid":
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(args[3])!, keyDown: down)
        if args.count > 4 { e?.flags = .maskCommand }
        e?.postToPid(pid_t(args[2])!)
    }
case "text":
    let units = Array(args[2].utf16)
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units); e?.post(tap: .cghidEventTap)
case "ax", "find", "ax-subtree":
    let app = AXUIElementCreateApplication(pid_t(args[2])!)
    func value(_ e: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?; return AXUIElementCopyAttributeValue(e, attribute, &result) == .success ? result : nil
    }
    var count = 0
    func walk(_ element: AXUIElement, _ path: String) {
        guard count < 180 else { return }; count += 1
        let role = value(element, kAXRoleAttribute as CFString) as? String ?? ""
        if args.contains("--window-only"), role == "AXMenuBar" { return }
        // Never print file chooser contents or Finder sidebars.
        if args[1] != "find", role == "AXBrowser" || role == "AXOutline" { return }
        let title = value(element, kAXTitleAttribute as CFString) as? String ?? ""
        let description = value(element, kAXDescriptionAttribute as CFString) as? String ?? ""
        let content = value(element, kAXValueAttribute as CFString) as? String ?? ""
        if args[1] != "find" {
            print("\(path) \(role) \(title) \(description) \(content.prefix(160))")
        } else if [title, description, content].contains(where: { $0 == args[3] }) {
            var p = CGPoint.zero, s = CGSize.zero
            if let v = value(element, kAXPositionAttribute as CFString) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
            if let v = value(element, kAXSizeAttribute as CFString) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
            print("\(path) \(role) \(args[3]) at \(p.x),\(p.y) size \(s.width),\(s.height)")
        }
        for (i, child) in (value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []).enumerated() { walk(child, "\(path).\(i)") }
    }
    if args[1] == "ax-subtree" {
        var element = app
        for part in args[3].split(separator: ".") {
            element = (value(element, kAXChildrenAttribute as CFString) as! [AXUIElement])[Int(part)!]
        }
        walk(element, "app.\(args[3])")
    } else { walk(app, "app") }
default: fatalError("unknown QA operation")
}

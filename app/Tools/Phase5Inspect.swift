import AppKit
import CoreAudio
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
if CommandLine.arguments.contains("--finder-preview") {
    let app = AXUIElementCreateApplication(695)
    func describe(_ element: AXUIElement, depth: Int = 0) {
        guard depth < 8 else { return }
        let values = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { attribute(element, $0).map { String(describing: $0) } ?? "" }
        print(values.joined(separator: " | ").prefix(250))
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { describe(child, depth: depth + 1) }
    }
    for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        guard attribute(window, kAXSubroleAttribute) as? String == "Quick Look" else { continue }
        describe(window)
    }
}

// Read only diagnostics scoped to the phase-five probe and Quick Look helpers.
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
var query = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
let system = AudioObjectID(kAudioObjectSystemObject)
guard AudioObjectGetPropertyDataSize(system, &query, 0, nil, &size) == noErr else { fatalError("Cannot query audio processes") }
var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(system, &query, 0, nil, &size, &processes) == noErr else { fatalError("Cannot read audio processes") }
for object in processes {
    var bundle: Unmanaged<CFString>?, length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var bundleQuery = address(kAudioProcessPropertyBundleID)
    guard AudioObjectGetPropertyData(object, &bundleQuery, 0, nil, &length, &bundle) == noErr else { continue }
    guard let bundle else { continue }
    let name = bundle.takeUnretainedValue() as String
    guard name.lowercased().contains("quicklook") || name == "local.dump.phase5probe" else { continue }
    var pid: pid_t = 0, output: UInt32 = 0
    var pidQuery = address(kAudioProcessPropertyPID), outputQuery = address(kAudioProcessPropertyIsRunningOutput)
    length = UInt32(MemoryLayout<pid_t>.size)
    let pidStatus = AudioObjectGetPropertyData(object, &pidQuery, 0, nil, &length, &pid)
    length = UInt32(MemoryLayout<UInt32>.size)
    let outputStatus = AudioObjectGetPropertyData(object, &outputQuery, 0, nil, &length, &output)
    print("audio bundle=\(name) pid=\(pid) output=\(output) status=\(pidStatus)/\(outputStatus)")
}
for window in CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [] {
    guard CommandLine.arguments.contains("--all-qa") || (window[kCGWindowOwnerPID as String] as? Int) == CommandLine.arguments.last.flatMap(Int.init) else { continue }
    let title = window[kCGWindowName as String] as? String ?? ""
    if CommandLine.arguments.contains("--qa-only") || CommandLine.arguments.contains("--all-qa"), !title.contains("QA-") && !title.contains("Quick Look") && !title.contains("qa-phase5") { continue }
    print("window id=\(window[kCGWindowNumber as String]!) owner=\(window[kCGWindowOwnerName as String] ?? "") pid=\(window[kCGWindowOwnerPID as String] ?? 0) title=\(title) bounds=\(window[kCGWindowBounds as String]!)")
}

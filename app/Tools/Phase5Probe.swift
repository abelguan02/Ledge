import AppKit
import QuickLookUI
import WebKit

// Isolated capability probe: same borderless/floating/key-only panel as Dump.
// Never reads the user's library, browser profile, or clipboard.
@MainActor final class ProbePanel: NSPanel, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    var files: [URL] = []
    var permitsMain = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { permitsMain }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self; panel.delegate = self
            print("QL controller acquired; items=\(files.count)")
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil; panel.delegate = nil
            print("QL controller released")
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { files.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { files[index] as NSURL }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            let preview = QLPreviewPanel.shared()!
            preview.makeKeyAndOrderFront(nil)
            print("QL visible=\(preview.isVisible) controller=\(String(describing: preview.currentController)) index=\(preview.currentPreviewItemIndex)")
        } else if event.keyCode == 53 { NSApp.terminate(nil) }
        else { super.keyDown(with: event) }
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        print("QL event=\(event.type.rawValue) key=\(event.keyCode) index=\(panel.currentPreviewItemIndex)")
        return false
    }
    func windowWillClose(_ notification: Notification) { print("QL window closed") }
}

@MainActor final class SnapshotProbe: NSObject, WKNavigationDelegate, WKUIDelegate {
    var web: WKWebView!
    var deadline: Task<Void, Never>?
    var finishing = false
    var completed = false
    let output: URL
    let target: URL
    init(target: URL, output: URL) { self.target = target; self.output = output }
    func run() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        web.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        deadline = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { finish("FAIL timeout", status: 1) } }
        print("SNAPSHOT start nonPersistent=\(!config.websiteDataStore.isPersistent) viewport=1280x800")
        web.load(URLRequest(url: target))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = ["http", "https"].contains(action.request.url?.scheme?.lowercased() ?? "") && !action.shouldPerformDownload
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finishing else { return }; finishing = true
        Task {
            do {
                try await Task.sleep(for: .milliseconds(1500))
                let snapshot = WKSnapshotConfiguration(); snapshot.rect = CGRect(x: 0, y: 0, width: 1280, height: 800); snapshot.snapshotWidth = 1280
                let image = try await webView.takeSnapshot(configuration: snapshot)
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: output, options: .atomic)
                let cookieCount = await webView.configuration.websiteDataStore.httpCookieStore.allCookies().count
                finish("PASS snapshot pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) bytes=\(png.count) title=\(webView.title ?? "") cookies=\(cookieCount) output=\(output.path)", status: 0)
            } catch { finish("FAIL snapshot \(error)", status: 1) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish("FAIL load \(error)", status: 1) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish("FAIL provisional \(error)", status: 1) }
    func finish(_ message: String, status: Int32) {
        guard !completed else { return }; completed = true
        deadline?.cancel(); web.stopLoading(); print(message); exit(status)
    }
}

@main @MainActor struct Phase5Probe {
    static func main() throws {
        let app = NSApplication.shared
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Phase5Probe")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--snapshot") {
            app.setActivationPolicy(.prohibited)
            let target = URL(string: CommandLine.arguments.last!)!
            let runner = SnapshotProbe(target: target, output: output.appendingPathComponent("snapshot.png"))
            runner.run(); withExtendedLifetime(runner) { app.run() }
        } else {
            app.setActivationPolicy(.accessory)
            let text = output.appendingPathComponent("QA-preview.txt")
            try ("Dump 第五阶段合成预览材料\n" + String(repeating: "完整文字可以滚动查看。\n", count: 100)).write(to: text, atomically: true, encoding: .utf8)
            let wav = output.appendingPathComponent("QA-tone-45s.wav")
            var audio = Data()
            func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { audio.append(contentsOf: $0) } }
            let count: UInt32 = 44100 * 45
            audio.append(Data("RIFF".utf8)); number(UInt32(36 + count * 2)); audio.append(Data("WAVEfmt ".utf8)); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(44100)); number(UInt32(88200)); number(UInt16(2)); number(UInt16(16)); audio.append(Data("data".utf8)); number(count * 2)
            for i in 0..<count { number(Int16(sin(Double(i) * 2 * .pi * 440 / 44100) * 1500)) }
            try audio.write(to: wav)
            let standard = CommandLine.arguments.contains("--standard-window")
            let panel = ProbePanel(contentRect: NSRect(x: 500, y: 250, width: 540, height: 768), styleMask: standard ? [.titled, .closable] : .borderless, backing: .buffered, defer: false)
            panel.permitsMain = standard
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            if standard { panel.level = .normal }
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.title = "Dump 第五阶段能力验证"
            panel.files = [text, wav]
            if let media = Bundle.main.url(forResource: "QA-video", withExtension: "mp4") {
                let copy = output.appendingPathComponent("QA-motion-30s.mp4")
                try Data(contentsOf: media).write(to: copy, options: .atomic)
                panel.files.append(copy)
            }
            let screenshot = output.appendingPathComponent("snapshot.png")
            if FileManager.default.fileExists(atPath: screenshot.path) { panel.files.append(screenshot) }
            let label = NSTextField(wrappingLabelWithString: "Dump 第五阶段隔离验证\n\n空格：系统预览\n左右方向键：切换文字、音频、视频、网页截图\n预览关闭后 Esc：结束验证\n\n不读取原收集区，不使用剪贴板。")
            label.frame = NSRect(x: 24, y: 440, width: 490, height: 240); panel.contentView?.addSubview(label)
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel)
            withExtendedLifetime(panel) { app.run() }
        }
    }
}

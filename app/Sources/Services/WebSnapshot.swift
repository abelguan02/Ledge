import AppKit
import WebKit

struct WebSnapshot: Sendable {
    var png: Data
    var title: String?
    var siteName: String?
}
typealias WebSnapshotOperation = @MainActor (URL, Bool, @escaping @MainActor (Double) -> Void) async throws -> WebSnapshot
enum WebSnapshotError: Error, LocalizedError, Equatable {
    case failed, timedOut, needsLogin, needsConsent
    var errorDescription: String? {
        switch self {
        case .failed: "没能生成预览"
        case .timedOut: "网页加载超过 20 秒，没能生成预览"
        case .needsLogin: "需要登录才能看到"
        case .needsConsent: "这类链接不自动打开"
        }
    }
}

@MainActor final class WebSnapshotCapture: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView?
    private var continuation: CheckedContinuation<WebSnapshot, Error>?
    private var timeout: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var progressObservation: NSKeyValueObservation?
    private var permitsOneTime = false

    func capture(_ url: URL, permitsOneTime: Bool = false, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> WebSnapshot {
        try Task.checkCancellation()
        guard Library.webURL(url.absoluteString) != nil else { throw WebSnapshotError.failed }
        guard permitsOneTime || !LinkPreviewPolicy.requiresConsent(url) else { throw WebSnapshotError.needsConsent }
        self.permitsOneTime = permitsOneTime
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                config.mediaTypesRequiringUserActionForPlayback = .all
                config.preferences.javaScriptCanOpenWindowsAutomatically = false
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
                web = view; view.navigationDelegate = self; view.uiDelegate = self
                view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
                progressObservation = view.observe(\.estimatedProgress, options: [.new]) { _, change in
                    let value = change.newValue ?? 0
                    Task { @MainActor in progress(value * 0.9) }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(.failure(WebSnapshotError.timedOut))
                }
                view.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
    private func finish(_ result: Result<WebSnapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil; settling?.cancel(); settling = nil
        progressObservation?.invalidate(); progressObservation = nil
        let finishedWeb = web
        web = nil
        // Policy callbacks can still be inside WebKit's provisional-page response
        // dispatch. Keep the view alive until that stack unwinds before closing it.
        DispatchQueue.main.async {
            finishedWeb?.navigationDelegate = nil; finishedWeb?.uiDelegate = nil
            finishedWeb?.stopLoading()
            finishedWeb?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            continuation.resume(with: result)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, Library.webURL(url.absoluteString) != nil, !action.shouldPerformDownload else {
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame == true { finish(.failure(WebSnapshotError.failed)) }
            return
        }
        guard permitsOneTime || !LinkPreviewPolicy.requiresConsent(url) else {
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame == true { finish(.failure(WebSnapshotError.needsConsent)) }
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if response.isForMainFrame, [401, 407].contains(status) {
            decisionHandler(.cancel); finish(.failure(WebSnapshotError.needsLogin)); return
        }
        if !response.canShowMIMEType || status >= 400 || http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true {
            decisionHandler(.cancel)
            if response.isForMainFrame { finish(.failure(WebSnapshotError.failed)) }
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil); finish(.failure(WebSnapshotError.needsLogin)) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settling?.cancel()
        settling = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1500))
                guard let self, self.continuation != nil else { return }
                // Read only the card's declared site metadata and visible access
                // gates; never extract page body text or send it to an AI service.
                let metadata = try await webView.evaluateJavaScript("""
                (() => {
                  const visible = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < 800 && getComputedStyle(e).visibility !== 'hidden'; };
                  return {site: document.querySelector('meta[property="og:site_name"]')?.content || '',
                    gated: [...document.querySelectorAll('input[type="password"], iframe[src*="captcha"], iframe[src*="challenge"]')].some(visible)};
                })()
                """) as? [String: Any]
                try Task.checkCancellation()
                if metadata?["gated"] as? Bool == true { self.finish(.failure(WebSnapshotError.needsLogin)); return }
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: 1280, height: 800); config.snapshotWidth = 1280
                let image = try await webView.takeSnapshot(configuration: config)
                try Task.checkCancellation()
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw WebSnapshotError.failed }
                func nonempty(_ value: String?) -> String? {
                    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.flatMap { $0.isEmpty ? nil : $0 }
                }
                self.finish(.success(WebSnapshot(png: png, title: nonempty(webView.title), siteName: nonempty(metadata?["site"] as? String))))
            } catch is CancellationError { }
            catch { self?.finish(.failure(WebSnapshotError.failed)) }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        settling?.cancel(); settling = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(WebSnapshotError.failed)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(WebSnapshotError.failed)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(WebSnapshotError.failed)) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}

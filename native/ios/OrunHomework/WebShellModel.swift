import Foundation
import SafariServices
import SwiftUI
import UIKit
import WebKit

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ExternalPage: Identifiable {
    let id = UUID()
    let url: URL
}

enum ShellLimits {
    static let fileSize = 40 * 1024 * 1024
    /// Largest base64 payload accepted in one script message (~390 KB of JSON string).
    static let chunkBytes = 400_000
    static let transferTimeout: TimeInterval = 180
    /// Minimum gap between foreground build checks, so returning to the app repeatedly
    /// does not turn into a request loop.
    static let buildProbeInterval: TimeInterval = 60
}

private enum ShellError: Error { case rejected }

private final class ShellMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WebShellModel?

    @MainActor func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveShellMessage(message)
    }
}

private final class FileMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: WebShellModel?

    @MainActor func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Unavailable"); return }
        owner.receiveFileMessage(message, reply: replyHandler)
    }
}

/// The whole app: one WKWebView pointed at the deployed homework site.
///
/// Nothing about the web build is bundled here, so publishing web changes is enough for
/// App Store users to get them. The shell's job is only to (1) always request the live
/// document instead of a stored copy, (2) notice a new deployment when the app comes back
/// to the foreground, and (3) keep recording, camera, file and link handling intact.
@MainActor
final class WebShellModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isLoading = true
    @Published private(set) var failure: String?
    @Published var sharedFile: SharedFile?
    @Published var externalPage: ExternalPage?
    @Published var alertMessage: String?

    let webView: WKWebView

    private let shellProxy = ShellMessageProxy()
    private let fileProxy = FileMessageProxy()
    private var captureActive = false
    private var loadedSignature: String?
    private var lastProbeDate: Date?
    private var probeInFlight = false
    private var incoming: IncomingFile?
    private var transferTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?

    private struct IncomingFile {
        let destination: URL
        let expected: Int
        var data: Data
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        // Persistent store: the access-code session and page storage must survive app
        // restarts exactly as they do in Safari. Only the document request is forced
        // to the network, never the user's session.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        shellProxy.owner = self
        fileProxy.owner = self

        let controller = webView.configuration.userContentController
        controller.add(shellProxy, contentWorld: .page, name: "orunShell")
        controller.addScriptMessageHandler(fileProxy, contentWorld: .page, name: "orunFile")
        controller.addUserScript(WKUserScript(source: WebShellScripts.captureTracker,
                                             injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true,
                                             in: .page))
        controller.addUserScript(WKUserScript(source: WebShellScripts.fileBridge,
                                             injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false,
                                             in: .page))

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)

        load()
    }

    // MARK: - Loading

    func load() {
        failure = nil
        isLoading = true
        loadedSignature = nil
        webView.load(documentRequest())
    }

    /// Network-first document request. The HTML is the only thing that can pin an old
    /// UI; content-hashed assets are immutable, so they may come from the disk cache.
    private func documentRequest() -> URLRequest {
        var request = URLRequest(url: Site.rootURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    /// Called when the app becomes active again. Reloads only when the deployment has
    /// really changed, only on the site's entry screen, and never during a recording.
    func refreshIfStale() {
        guard failure == nil, !isLoading, !webView.isLoading, !captureActive,
              incoming == nil, downloadTask == nil, !probeInFlight else { return }
        guard isAtRoot() else { return }
        if let lastProbeDate, Date().timeIntervalSince(lastProbeDate) < ShellLimits.buildProbeInterval { return }
        probeInFlight = true
        lastProbeDate = Date()
        probeBuildSignature { [weak self] signature in
            guard let self else { return }
            self.probeInFlight = false
            guard let signature else { return }
            guard let known = self.loadedSignature else {
                self.loadedSignature = signature
                return
            }
            guard known != signature, !self.captureActive else { return }
            self.load()
        }
    }

    private func isAtRoot() -> Bool {
        guard let url = webView.url, Site.isTrusted(url) else { return false }
        return url.path.isEmpty || url.path == "/"
    }

    private func probeBuildSignature(completion: @escaping @MainActor (String?) -> Void) {
        var request = URLRequest(url: Site.rootURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        URLSession(configuration: configuration).dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var signature: String?
            if status == 200, let data, let html = String(data: data, encoding: .utf8) {
                signature = Site.assetSignature(in: html)
            }
            let result = signature
            Task { @MainActor in completion(result) }
        }.resume()
    }

    // MARK: - Site build identity

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isLoading = false
        failure = nil
        webView.evaluateJavaScript(WebShellScripts.currentBuild) { value, _ in
            guard let signature = value as? String, !signature.isEmpty else { return }
            Task { @MainActor [weak self] in self?.loadedSignature = signature }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        load()
    }

    private func report(_ error: Error, in webView: WKWebView) {
        guard webView === self.webView else { return }
        let error = error as NSError
        // Cancellation is how a policy decision (external link, download) looks here.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        isLoading = false
        failure = "숙제 화면을 열지 못했어요.\n인터넷 연결을 확인한 뒤 다시 시도해 주세요."
    }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }

        // New window / target=_blank.
        if navigationAction.targetFrame == nil {
            if Site.isTrusted(url) {
                webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
            } else {
                openOutsideApp(url)
            }
            decisionHandler(.cancel)
            return
        }

        // Third-party frames (the review video embed) load as they would in a browser.
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }

        if Site.isTrusted(url) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.cancel)
                startDownload(url)
            } else {
                decisionHandler(.allow)
            }
            return
        }

        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }

        openOutsideApp(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isDownload = disposition.contains("attachment") || !navigationResponse.canShowMIMEType
        if navigationResponse.isForMainFrame, isDownload {
            guard Site.isTrusted(response.url), Site.isTrusted(webView.url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
            if let url = response.url { startDownload(url) }
            return
        }
        decisionHandler(.allow)
    }

    private func openOutsideApp(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "mailto", "tel":
            UIApplication.shared.open(url)
        case "http", "https":
            externalPage = ExternalPage(url: url)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, let url = navigationAction.request.url else { return nil }
        if Site.isTrusted(url) {
            webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        } else {
            openOutsideApp(url)
        }
        return nil
    }

    /// Microphone and camera capture is granted to this one trusted origin only, so the
    /// recording and photo-submission screens work without WebKit asking on every take.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard webView === self.webView, Site.isTrustedOrigin(origin) else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(.grant)
    }

    // MARK: - Server files (report PDFs, attachments)

    /// Downloads a server file with the web view's own cookies, so a link that works in
    /// the page works here too, and hands it to the share sheet.
    private func startDownload(_ url: URL) {
        guard downloadTask == nil, incoming == nil else {
            alertMessage = "다른 파일을 저장하는 중이에요. 끝난 뒤 다시 시도해 주세요."
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let fields = HTTPCookie.requestHeaderFields(with: cookies)
            Task { @MainActor in
                self?.performDownload(url, cookieFields: fields)
            }
        }
    }

    private func performDownload(_ url: URL, cookieFields: [String: String]) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        for (name, value) in cookieFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let suggested = response?.suggestedFilename
            let contentType = response?.mimeType
            let expected = response?.expectedContentLength ?? -1
            Task { @MainActor in
                self?.finishDownload(temporaryURL: temporaryURL,
                                     status: status,
                                     suggestedName: suggested,
                                     mimeType: contentType,
                                     expectedBytes: expected,
                                     error: error)
            }
        }
        downloadTask = task
        task.resume()
    }

    private func finishDownload(temporaryURL: URL?, status: Int, suggestedName: String?, mimeType: String?, expectedBytes: Int64, error: Error?) {
        downloadTask = nil
        guard error == nil, (200...299).contains(status), let temporaryURL,
              expectedBytes <= Int64(ShellLimits.fileSize) else {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            alertMessage = "파일을 저장하지 못했어요. 연결과 파일 크기(최대 40MB)를 확인한 뒤 다시 시도해 주세요."
            return
        }
        let name = suggestedName ?? "download"
        do {
            let destination = try makeDestination(name: name)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            sharedFile = SharedFile(url: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            alertMessage = "파일을 저장하지 못했어요. 저장 공간을 확인한 뒤 다시 시도해 주세요."
        }
        _ = mimeType
    }

    // MARK: - Files built in the page (blob/data path)

    fileprivate func receiveShellMessage(_ message: WKScriptMessage) {
        guard message.name == "orunShell",
              message.webView === webView,
              trustedFrame(message.frameInfo),
              let body = message.body as? [String: Any],
              let op = body["op"] as? String, op == "capture" else { return }
        captureActive = (body["active"] as? Bool) ?? false
    }

    fileprivate func receiveFileMessage(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        guard message.name == "orunFile",
              trustedFrame(message.frameInfo),
              let body = message.body as? [String: Any],
              let op = body["op"] as? String else {
            reply(nil, "Not allowed")
            return
        }
        do {
            switch op {
            case "begin":
                guard incoming == nil, downloadTask == nil,
                      let name = body["name"] as? String, name.utf8.count <= 400,
                      body["mime"] is String,
                      let size = body["size"] as? Int, size > 0, size <= ShellLimits.fileSize else {
                    throw ShellError.rejected
                }
                let destination = try makeDestination(name: name)
                incoming = IncomingFile(destination: destination, expected: size, data: Data())
                scheduleTransferTimeout()
            case "chunk":
                guard var current = incoming,
                      let encoded = body["data"] as? String, encoded.utf8.count <= ShellLimits.chunkBytes,
                      let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                      current.data.count + bytes.count <= current.expected else {
                    throw ShellError.rejected
                }
                current.data.append(bytes)
                incoming = current
            case "end":
                guard let current = incoming, current.data.count == current.expected else {
                    throw ShellError.rejected
                }
                try current.data.write(to: current.destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                transferTimer?.invalidate()
                transferTimer = nil
                incoming = nil
                sharedFile = SharedFile(url: current.destination)
            case "error":
                abortTransfer(notifyUser: true)
            default:
                throw ShellError.rejected
            }
            reply(["ok": true], nil)
        } catch {
            abortTransfer(notifyUser: true)
            reply(nil, "Transfer rejected")
        }
    }

    private func scheduleTransferTimeout() {
        transferTimer?.invalidate()
        transferTimer = Timer.scheduledTimer(withTimeInterval: ShellLimits.transferTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.abortTransfer(notifyUser: true) }
        }
    }

    private func abortTransfer(notifyUser: Bool) {
        transferTimer?.invalidate()
        transferTimer = nil
        if let current = incoming {
            try? FileManager.default.removeItem(at: current.destination.deletingLastPathComponent())
        }
        incoming = nil
        if notifyUser {
            alertMessage = "파일을 저장하지 못했어요. 잠시 후 다시 시도해 주세요."
        }
    }

    /// Removes the temporary copy once the share sheet closes.
    func cleanupSharedFile() {
        guard let file = sharedFile else { return }
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        sharedFile = nil
    }

    private func makeDestination(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrunHomework-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                               withIntermediateDirectories: false,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return directory.appendingPathComponent(Self.safeName(name), isDirectory: false)
    }

    private static func safeName(_ raw: String) -> String {
        let base = raw.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "download"
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = base.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !forbidden.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let limited = String(cleaned.prefix(120))
        return limited.isEmpty ? "download" : limited
    }

    private func trustedFrame(_ frame: WKFrameInfo) -> Bool {
        Site.isTrustedOrigin(frame.securityOrigin) && Site.isTrusted(webView.url)
    }
}

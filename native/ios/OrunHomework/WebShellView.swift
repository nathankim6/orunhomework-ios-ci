import SafariServices
import SwiftUI
import WebKit

/// The visible app. The web view is placed inside the safe area on purpose: the site is
/// plain `width=device-width` markup without `viewport-fit=cover`, so keeping the view
/// inside the safe area means no text hides under the notch or the home indicator, and
/// the shell paints the surrounding status-bar area with the site's own dark navy.
struct WebShellView: View {
    @StateObject private var model = WebShellModel()
    @Environment(\.scenePhase) private var scenePhase

    private static let background = Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255)

    var body: some View {
        ZStack {
            Self.background.ignoresSafeArea()

            if let failure = model.failure {
                FailurePanel(message: failure) { model.load() }
            } else {
                WebViewContainer(webView: model.webView)
            }

            if model.isLoading {
                ProgressView("숙제 화면 여는 중…")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(Self.background)
            }
        }
        .alert("파일 저장", isPresented: Binding(get: { model.alertMessage != nil },
                                               set: { if !$0 { model.alertMessage = nil } })) {
            Button("확인") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .sheet(item: $model.sharedFile, onDismiss: { model.cleanupSharedFile() }) { file in
            ShareSheet(url: file.url)
        }
        .sheet(item: $model.externalPage) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refreshIfStale() }
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct FailurePanel: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text("숙제 화면 연결 오류")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
            Button("다시 시도", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255))
                .padding(.top, 4)
        }
        .padding(28)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

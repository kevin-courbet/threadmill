import SwiftUI
import WebKit

struct WebViewWrapper: NSViewRepresentable {
    let url: String
    let sessionID: String
    let onNavigationStateChange: (Bool, Bool, Bool, Double) -> Void
    let onURLChange: (String) -> Void
    let onTitleChange: (String) -> Void
    let onNewTab: (String) -> Void
    let onWebViewCreated: (WKWebView) -> Void
    let onLoadError: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = true

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = webpagePreferences
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        context.coordinator.attach(to: webView)
        context.coordinator.lastLoadedURL = url
        onWebViewCreated(webView)
        load(urlString: url, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard !url.isEmpty else {
            return
        }

        // Only navigate when URL bar changes (navigateToURL), not on KVO feedback
        if context.coordinator.lastLoadedURL == url {
            return
        }

        context.coordinator.lastLoadedURL = url
        load(urlString: url, into: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: webView)
    }

    private func load(urlString: String, into webView: WKWebView) {
        guard let destinationURL = URL(string: urlString) else {
            onLoadError("Invalid URL: \(urlString)")
            return
        }

        onLoadError(nil)
        webView.load(URLRequest(url: destinationURL))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebViewWrapper
        // Tracks the last URL we programmatically loaded to avoid re-navigation on KVO feedback
        var lastLoadedURL: String?
        private var progressObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?

        init(parent: WebViewWrapper) {
            self.parent = parent
        }

        deinit {
            progressObserver?.invalidate()
            urlObserver?.invalidate()
            titleObserver?.invalidate()
        }

        func attach(to webView: WKWebView) {
            progressObserver?.invalidate()
            urlObserver?.invalidate()
            titleObserver?.invalidate()

            progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] observed, _ in
                guard let self else {
                    return
                }
                self.parent.onNavigationStateChange(
                    observed.canGoBack,
                    observed.canGoForward,
                    observed.isLoading,
                    observed.estimatedProgress
                )
            }

            urlObserver = webView.observe(\.url, options: [.new]) { [weak self] observed, _ in
                guard let self,
                      let updatedURL = observed.url?.absoluteString
                else {
                    return
                }
                self.parent.onURLChange(updatedURL)
            }

            titleObserver = webView.observe(\.title, options: [.new]) { [weak self] observed, _ in
                guard let self,
                      let updatedTitle = observed.title
                else {
                    return
                }
                self.parent.onTitleChange(updatedTitle)
            }
        }

        func detach(from webView: WKWebView) {
            progressObserver?.invalidate()
            urlObserver?.invalidate()
            titleObserver?.invalidate()
            progressObserver = nil
            urlObserver = nil
            titleObserver = nil
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.stopLoading()
        }

        func webView(_ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
            if let destination = navigationAction.request.url?.absoluteString {
                parent.onNewTab(destination)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            parent.onLoadError(nil)
            parent.onNavigationStateChange(webView.canGoBack, webView.canGoForward, true, webView.estimatedProgress)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            parent.onNavigationStateChange(webView.canGoBack, webView.canGoForward, false, webView.estimatedProgress)
            if let currentURL = webView.url?.absoluteString {
                parent.onURLChange(currentURL)
            }
            if let currentTitle = webView.title {
                parent.onTitleChange(currentTitle)
            }
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            parent.onNavigationStateChange(webView.canGoBack, webView.canGoForward, false, webView.estimatedProgress)
            parent.onLoadError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            parent.onNavigationStateChange(webView.canGoBack, webView.canGoForward, false, webView.estimatedProgress)
            parent.onLoadError(error.localizedDescription)
        }
    }
}

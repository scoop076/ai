// The web view that shows the frame, plus the message bridge the page uses
// to ask the app to listen, play audio, or speak with a device voice.

import SwiftUI
import WebKit

let frameURL = URL(string: "https://ai.liljimjim.com")!
let miboOrange = UIColor(red: 217/255, green: 119/255, blue: 21/255, alpha: 1)   // #D97715

struct FrameWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()            // keeps the Cloudflare sign-in between launches
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "ClaudeFrameApp/1.0"
        config.userContentController.add(context.coordinator, name: "frame")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = miboOrange           // matches the page's glow, so loading and pull-to-reload stay orange
        web.scrollView.backgroundColor = miboOrange
        web.scrollView.alwaysBounceVertical = true   // pull down on the frame to reload it
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pulledToReload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.web = web
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { web.isInspectable = true }   // lets Safari on the Mac debug it
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator

        NativeAudio.shared.send = { [weak web] event in
            guard let web,
                  let data = try? JSONSerialization.data(withJSONObject: event),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.__frameNative && window.__frameNative(\(json))", completionHandler: nil)
        }
        web.load(URLRequest(url: frameURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var web: WKWebView?

        @objc func pulledToReload(_ sender: UIRefreshControl) {
            sender.endRefreshing()
            web?.load(URLRequest(url: frameURL))
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            NativeAudio.shared.handle(body)
        }

        // A new page is loading (an update reload or sign-in): stop any sound from the old one.
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            NativeAudio.shared.stopAll()
        }

        // Links that try to open a new window open here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            if e.code == NSURLErrorCancelled || e.code == 102 { return }   // redirects, not real failures
            showOffline(webView)
        }

        // If the page's process is ever killed by the system, bring it back.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(URLRequest(url: frameURL))
        }

        private func showOffline(_ webView: WKWebView) {
            let html = """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{background:radial-gradient(circle at 50% 45%,#eaa766,#d97715 40%,#a95d10);color:#2b1f27;font:20px -apple-system,sans-serif;display:flex;
            height:100vh;margin:0;align-items:center;justify-content:center;text-align:center}
            button{font:inherit;padding:14px 26px;border-radius:14px;border:0;background:#2b1f27;color:#fff;margin-top:18px}</style></head>
            <body><div>I can't reach the frame right now.<br>Check the Wi-Fi.<br>
            <button onclick="location.href='\(frameURL.absoluteString)'">Try again</button></div>
            <script>setTimeout(function(){location.href='\(frameURL.absoluteString)'},15000)</script></body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

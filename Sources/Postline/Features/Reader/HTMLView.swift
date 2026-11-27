import SwiftUI
import WebKit

/// An email's HTML, drawn by WebKit at its full height inside the reader's
/// own scroll view (the web view never scrolls by itself).
///
/// The mail's own scripts never run; links open in the default browser.
/// With `allowsRemoteContent`, remote images, style sheets and fonts load,
/// after TrackingImageFilter has removed the open-tracking pixels; without
/// it, nothing remote loads. The page may not navigate anywhere by itself
/// either (a meta refresh or a form would otherwise load a remote page
/// inside the reader).
///
/// The text is drawn as soon as it is laid out, and images fill in as they
/// arrive. Until 2026-11-27 nothing was drawn before every image had loaded:
/// one slow image server kept an email blank for 8 s although its text was
/// ready after 0.65 s (measured). A small script of Postline's own, in a
/// world of its own that the email cannot reach, reports the page's height
/// as it changes and how many images are still loading; each of those shows
/// a placeholder in the space it will take.
struct HTMLView: NSViewRepresentable {
    let html: String
    var allowsRemoteContent = false
    @Binding var height: CGFloat
    /// Images still loading, for the reader's loading indicator.
    @Binding var loadingImages: Int
    /// Called once the text is shown, for the reader's timing.
    var onReady: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, loadingImages: $loadingImages) }

    func makeNSView(context: Context) -> PassiveWebView {
        let view = Performance.measure("reader.webview_create") {
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            // No cookies, cache or storage shared between emails or kept on disk.
            config.websiteDataStore = .nonPersistent()
            let controller = config.userContentController
            controller.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: .defaultClient))
            controller.add(context.coordinator, contentWorld: .defaultClient, name: Self.pageChannel)
            return PassiveWebView(frame: .zero, configuration: config)
        }
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.onReady = onReady
        load(view, context: context)
        return view
    }

    func updateNSView(_ view: PassiveWebView, context: Context) {
        context.coordinator.onReady = onReady
        guard context.coordinator.loaded != pageKey else { return }
        load(view, context: context)
    }

    static func dismantleNSView(_ view: PassiveWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: pageChannel, contentWorld: .defaultClient)
    }

    private var pageKey: String { (allowsRemoteContent ? "remote:" : "local:") + html }

    private func load(_ view: PassiveWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.loaded = pageKey
        let kilobytes = "\(html.utf8.count / 1024)"
        var removed = 0
        let document = Performance.measure("reader.prepare_html", ["kb": kilobytes]) {
            var page = html
            if allowsRemoteContent {
                let stripped = TrackingImageFilter.strip(html)
                page = stripped.html
                removed = stripped.removed
            }
            return Self.wrap(page, allowsRemoteContent: allowsRemoteContent)
        }
        coordinator.begin(detail: ["kb": kilobytes, "remote": allowsRemoteContent ? "on" : "off", "trackers": "\(removed)"])
        view.loadHTMLString(document, baseURL: nil)
    }

    /// The Content-Security-Policy for the page. Blocked: only inline styles
    /// and images embedded in the email itself. Allowed: remote images,
    /// style sheets, fonts and media too. Scripts and frames never load.
    static func contentPolicy(allowsRemoteContent: Bool) -> String {
        allowsRemoteContent
            ? "default-src 'none'; img-src * data: cid:; style-src * 'unsafe-inline'; font-src * data:; media-src *"
            : "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:"
    }

    /// Mail is designed for a white page; it gets one, with the system font
    /// for mail that names none and nothing wider than the reader. An image
    /// still loading shows a soft shimmer in its space (`postline-loading`,
    /// set by `pageScript`); images that say their size keep that space.
    static func wrap(_ html: String, allowsRemoteContent: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentPolicy(allowsRemoteContent: allowsRemoteContent))">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body { margin: 0; padding: 0; background: #fff; }
          body { font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #3f3f46;
                 word-wrap: break-word; overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; }
          img { max-width: 100% !important; height: auto; }
          img.postline-loading { background: linear-gradient(90deg, #f4f4f5 25%, #e9e9ec 37%, #f4f4f5 63%);
                                 background-size: 400% 100%; border-radius: 4px;
                                 animation: postline-shimmer 1.4s ease-in-out infinite; }
          @keyframes postline-shimmer { from { background-position: 100% 50%; } to { background-position: 0 50%; } }
          @media (prefers-reduced-motion: reduce) { img.postline-loading { animation: none; } }
          table { max-width: 100% !important; }
          pre { white-space: pre-wrap; }
          a { color: #2563eb; }
          blockquote { margin: 8px 0; padding-left: 12px; border-left: 2px solid #e4e4e7; color: #71717a; }
        </style></head><body>\(html)</body></html>
        """
    }

    private static let pageChannel = "page"

    /// Postline's script, run in its own world once the document is parsed:
    /// marks the images still loading, then reports `ready` (with the height
    /// and how many images are loading), `height` whenever the page changes
    /// size, and `images` as each image arrives or fails.
    private static let pageScript = """
    (() => {
      const channel = webkit.messageHandlers.\(pageChannel);
      const height = () => Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
      const loading = new Set();
      for (const image of document.images) {
        if (image.complete) continue;
        loading.add(image);
        image.classList.add('postline-loading');
        const arrived = () => {
          image.classList.remove('postline-loading');
          loading.delete(image);
          channel.postMessage({ kind: 'images', loading: loading.size, height: height() });
        };
        image.addEventListener('load', arrived, { once: true });
        image.addEventListener('error', arrived, { once: true });
      }
      channel.postMessage({ kind: 'ready', loading: loading.size, height: height() });
      new ResizeObserver(() => channel.postMessage({ kind: 'height', height: height() }))
        .observe(document.documentElement);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat
        @Binding var loadingImages: Int
        var loaded: String?
        var onReady: (() -> Void)?
        /// The page being loaded, for the timing.
        private var pageLoad: Performance.Interval?
        private var pageDetail: [String: String] = [:]
        private var readyReported = false

        init(height: Binding<CGFloat>, loadingImages: Binding<Int>) {
            _height = height
            _loadingImages = loadingImages
        }

        func begin(detail: [String: String]) {
            pageDetail = detail
            pageLoad = Performance.begin("reader.page_load")
            readyReported = false
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let h = body["height"] as? CGFloat { apply(height: h) }
            if let count = body["loading"] as? Int, loadingImages != count { loadingImages = count }
            if body["kind"] as? String == "ready" { reportReady() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finishLoading()
            // A last measurement, in case the script could not report.
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] value, _ in
                if let h = value as? CGFloat { self?.apply(height: h) }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishLoading(["failed": "yes"])
        }

        private func apply(height h: CGFloat) {
            guard h > 0, abs(h - height) > 1 else { return }
            height = h
        }

        /// The text is laid out and drawn; images may still be loading.
        private func reportReady() {
            guard !readyReported else { return }
            readyReported = true
            if let pageLoad { Performance.record("reader.dom_ready", ms: pageLoad.elapsed, detail: pageDetail) }
            onReady?()
        }

        private func finishLoading(_ extra: [String: String] = [:]) {
            pageLoad?.end(pageDetail.merging(extra) { $1 })
            pageLoad = nil
            if loadingImages != 0 { loadingImages = 0 }
            reportReady()
        }

        /// Only the email itself loads in the view (`about:blank`, from
        /// `loadHTMLString`). A clicked link opens in the browser; every other
        /// navigation (meta refresh, form submission, frame) is refused.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            if action.navigationType == .linkActivated {
                if let url, HTMLView.opensExternally(url) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else if action.targetFrame?.isMainFrame == true, url?.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

extension HTMLView {
    /// Links the browser or Mail can take: web pages and email addresses.
    static func opensExternally(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    private static let remoteReference = try! NSRegularExpression(pattern: #"""
    (?ix)
      \b(?:src|srcset|background|poster)\s*=\s*["']?\s*(?:https?:)?//
    | url\(\s*["']?\s*(?:https?:)?//
    | @import\s+["']?\s*(?:url\(\s*["']?)?\s*(?:https?:)?//
    | <link\b[^>]*\bhref\s*=\s*["']?\s*(?:https?:)?//
    """#)

    /// True when the email asks for something from the network (an image, a
    /// style sheet, a font); with remote images off, the reader then offers to
    /// load them.
    static func referencesRemoteContent(_ html: String) -> Bool {
        remoteReference.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }
}

/// Hands scrolling to the reader around it, so a long email scrolls with
/// its thread instead of trapping the wheel.
final class PassiveWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

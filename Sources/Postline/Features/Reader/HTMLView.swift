import SwiftUI
import WebKit

/// An email's HTML, drawn by WebKit at its full height inside the reader's
/// own scroll view (the web view never scrolls by itself).
///
/// The mail's own scripts never run; links open in the default browser.
/// With `allowsRemoteContent`, remote images, style sheets and fonts load,
/// after TrackingImageFilter has removed the open-tracking pixels; without
/// it, nothing remote loads. The page may not
/// navigate anywhere by itself either (a meta refresh or a form would
/// otherwise load a remote page inside the reader).
/// The height is measured once the page loads and again as late images
/// arrive and push it taller.
struct HTMLView: NSViewRepresentable {
    let html: String
    var allowsRemoteContent = false
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassiveWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        // No cookies, cache or storage shared between emails or kept on disk.
        config.websiteDataStore = .nonPersistent()
        let view = PassiveWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(view, context: context)
        return view
    }

    func updateNSView(_ view: PassiveWebView, context: Context) {
        guard context.coordinator.loaded != pageKey else { return }
        load(view, context: context)
    }

    private var pageKey: String { (allowsRemoteContent ? "remote:" : "local:") + html }

    private func load(_ view: PassiveWebView, context: Context) {
        context.coordinator.loaded = pageKey
        let page = allowsRemoteContent ? TrackingImageFilter.strip(html).html : html
        view.loadHTMLString(Self.wrap(page, allowsRemoteContent: allowsRemoteContent), baseURL: nil)
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
    /// for mail that names none and nothing wider than the reader.
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
          table { max-width: 100% !important; }
          pre { white-space: pre-wrap; }
          a { color: #2563eb; }
          blockquote { margin: 8px 0; padding-left: 12px; border-left: 2px solid #e4e4e7; color: #71717a; }
        </style></head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var height: CGFloat
        var loaded: String?
        init(height: Binding<CGFloat>) { _height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            for delay in [0.0, 0.4, 1.2, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    webView?.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { value, _ in
                        guard let h = value as? CGFloat, h > 0, abs(h - (self?.height ?? 0)) > 1 else { return }
                        self?.height = h
                    }
                }
            }
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

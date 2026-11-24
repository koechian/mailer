import SwiftUI
import WebKit

/// An email's HTML, drawn by WebKit at its full height inside the reader's
/// own scroll view (the web view never scrolls by itself).
///
/// The mail's own scripts never run; links open in the default browser.
/// The height is measured once the page loads and again as late images
/// arrive and push it taller.
struct HTMLView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassiveWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        let view = PassiveWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.wrap(html), baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: PassiveWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    /// Mail is designed for a white page; it gets one, with the system font
    /// for mail that names none and nothing wider than the reader.
    static func wrap(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
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

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// Hands scrolling to the reader around it, so a long email scrolls with
/// its thread instead of trapping the wheel.
final class PassiveWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

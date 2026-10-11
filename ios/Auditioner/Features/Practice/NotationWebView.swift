import SwiftUI
import UIKit
import WebKit

/// One measure as laid out by Verovio (from the `ready` message).
struct NotationMeasureInfo: Equatable {
    var index: Int
    var number: String
    var qstamp: Double
}

/// Forwards script messages to a weakly held target so the WKUserContentController
/// (which retains its handlers) does not keep the coordinator alive.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Verovio notation in a WKWebView (Resources/Web.bundle/notation.html), with playback highlighting.
struct NotationWebView: UIViewRepresentable {
    static let messageName = "auditioner"

    var musicXML: String
    /// Beat (quarter notes from the start) whose notes are highlighted; `nil` clears the highlight.
    var highlightBeat: Double?
    var onReady: ((_ pages: Int, _ measures: [NotationMeasureInfo]) -> Void)? = nil
    var onTapNote: ((_ qstamp: Double) -> Void)? = nil
    var onError: ((_ message: String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(target: context.coordinator), name: NotationWebView.messageName)
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.loadPage()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadMusicXMLIfNeeded()
        context.coordinator.pushHighlight(highlightBeat)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: NotationWebView.messageName)
        uiView.navigationDelegate = nil
        uiView.stopLoading()
        coordinator.webView = nil
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: NotationWebView
        weak var webView: WKWebView?

        private var toolkitReady = false
        private var pageReady = false
        private var loadedXML: String?
        private var lastPushedBeat: Double?
        private var lastPushWasClear = false

        init(parent: NotationWebView) {
            self.parent = parent
            super.init()
        }

        /// Loads notation.html from Web.bundle (the whole bundle folder is readable so the scripts load).
        func loadPage() {
            guard let webView = webView else { return }
            guard let bundleURL = Bundle.main.url(forResource: "Web", withExtension: "bundle") else {
                parent.onError?(String(localized: "The notation viewer is missing from the app."))
                return
            }
            let htmlURL = bundleURL.appendingPathComponent("notation.html")
            guard FileManager.default.fileExists(atPath: htmlURL.path) else {
                parent.onError?(String(localized: "The notation viewer is missing from the app."))
                return
            }
            webView.loadFileURL(htmlURL, allowingReadAccessTo: bundleURL)
        }

        func loadMusicXMLIfNeeded() {
            guard toolkitReady, let webView = webView else { return }
            let xml = parent.musicXML
            if loadedXML == xml { return }
            loadedXML = xml
            pageReady = false
            lastPushedBeat = nil
            let base64 = Data(xml.utf8).base64EncodedString()
            let width = Int(webView.bounds.width.rounded())
            let script = "window.auditioner.load('\(base64)', \(width));"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error = error {
                    self?.parent.onError?(error.localizedDescription)
                }
            }
        }

        /// Sends the highlight to the page only when the beat changed.
        func pushHighlight(_ beat: Double?) {
            guard pageReady, let webView = webView else { return }
            if let beat = beat, beat.isFinite {
                if let last = lastPushedBeat, last == beat, !lastPushWasClear { return }
                lastPushedBeat = beat
                lastPushWasClear = false
                webView.evaluateJavaScript("window.auditioner.highlight(\(beat));", completionHandler: nil)
            } else {
                if lastPushWasClear { return }
                lastPushWasClear = true
                lastPushedBeat = nil
                webView.evaluateJavaScript("window.auditioner.clear();", completionHandler: nil)
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == NotationWebView.messageName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "init":
                toolkitReady = true
                loadMusicXMLIfNeeded()
            case "ready":
                pageReady = true
                let pages = (body["pages"] as? NSNumber)?.intValue ?? 1
                var measures: [NotationMeasureInfo] = []
                if let raw = body["measures"] as? [[String: Any]] {
                    for item in raw {
                        let index = (item["index"] as? NSNumber)?.intValue ?? measures.count
                        let number = (item["n"] as? String) ?? ""
                        let qstamp = (item["qstamp"] as? NSNumber)?.doubleValue ?? 0
                        measures.append(NotationMeasureInfo(index: index, number: number, qstamp: qstamp))
                    }
                }
                parent.onReady?(pages, measures)
                // Re-apply the current highlight on the freshly rendered page.
                lastPushedBeat = nil
                lastPushWasClear = false
                pushHighlight(parent.highlightBeat)
            case "tapNote":
                if let q = (body["qstamp"] as? NSNumber)?.doubleValue {
                    parent.onTapNote?(q)
                }
            case "error":
                let text = (body["message"] as? String) ?? String(localized: "The music couldn't be drawn.")
                parent.onError?(text)
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onError?(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onError?(error.localizedDescription)
        }
    }
}

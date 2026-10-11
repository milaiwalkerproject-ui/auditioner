import SwiftUI
import UIKit
import WebKit

/// A tap on a note in the editor page (Verovio's numbering of the measure, order among the layer's editable notes).
struct EditorNoteTap: Equatable {
    var measureIndex: Int
    var measureNumber: String
    /// -1 when the tapped note is not editable (another voice, a grace note).
    var noteOrder: Int
    var qstamp: Double
}

/// Verovio notation for the correction editor (Resources/Web.bundle/editor.html): tap to select,
/// selected note highlighted, bars that don't add up tinted, playback highlight for the preview.
struct EditorNotationWebView: UIViewRepresentable {
    static let messageName = "editor"

    var musicXML: String
    var selection: NoteAddress?
    /// Indices of measures to tint red.
    var flaggedMeasures: [Int]
    /// Beat (quarter notes from the start) whose notes are highlighted; `nil` clears the highlight.
    var highlightBeat: Double?
    var onReady: (() -> Void)? = nil
    var onTapNote: ((EditorNoteTap) -> Void)? = nil
    var onError: ((_ message: String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(target: context.coordinator), name: EditorNotationWebView.messageName)
        configuration.userContentController = contentController

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
        context.coordinator.pushSelection(selection)
        context.coordinator.pushFlags(flaggedMeasures)
        context.coordinator.pushHighlight(highlightBeat)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: EditorNotationWebView.messageName)
        uiView.navigationDelegate = nil
        uiView.stopLoading()
        coordinator.webView = nil
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: EditorNotationWebView
        weak var webView: WKWebView?

        private var toolkitReady = false
        private var pageReady = false
        private var loadedXML: String?
        private var pushedSelection: NoteAddress?
        private var pushedSelectionValid = false
        private var pushedFlags: [Int]?
        private var lastPushedBeat: Double?
        private var lastPushWasClear = false

        init(parent: EditorNotationWebView) {
            self.parent = parent
            super.init()
        }

        /// Loads editor.html from Web.bundle (the whole bundle folder is readable so the scripts load).
        func loadPage() {
            guard let webView = webView else { return }
            guard let bundleURL = Bundle.main.url(forResource: "Web", withExtension: "bundle") else {
                parent.onError?(String(localized: "The notation editor is missing from the app."))
                return
            }
            let htmlURL = bundleURL.appendingPathComponent("editor.html")
            guard FileManager.default.fileExists(atPath: htmlURL.path) else {
                parent.onError?(String(localized: "The notation editor is missing from the app."))
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
            let base64 = Data(xml.utf8).base64EncodedString()
            let width = Int(webView.bounds.width.rounded())
            let script = "window.editor.load('\(base64)', \(width));"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error = error {
                    self?.parent.onError?(error.localizedDescription)
                }
            }
        }

        func pushSelection(_ selection: NoteAddress?) {
            guard pageReady, let webView = webView else { return }
            if pushedSelectionValid && pushedSelection == selection { return }
            pushedSelection = selection
            pushedSelectionValid = true
            let measure = selection?.measureIndex ?? -1
            let order = selection?.noteIndex ?? -1
            webView.evaluateJavaScript("window.editor.select(\(measure), \(order));", completionHandler: nil)
        }

        func pushFlags(_ flags: [Int]) {
            guard pageReady, let webView = webView else { return }
            if let pushed = pushedFlags, pushed == flags { return }
            pushedFlags = flags
            let list = flags.map { String($0) }.joined(separator: ",")
            webView.evaluateJavaScript("window.editor.flagBars([\(list)]);", completionHandler: nil)
        }

        /// Sends the highlight to the page only when the beat changed.
        func pushHighlight(_ beat: Double?) {
            guard pageReady, let webView = webView else { return }
            if let beat = beat, beat.isFinite {
                if let last = lastPushedBeat, last == beat, !lastPushWasClear { return }
                lastPushedBeat = beat
                lastPushWasClear = false
                webView.evaluateJavaScript("window.editor.highlight(\(beat));", completionHandler: nil)
            } else {
                if lastPushWasClear { return }
                lastPushWasClear = true
                lastPushedBeat = nil
                webView.evaluateJavaScript("window.editor.clear();", completionHandler: nil)
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == EditorNotationWebView.messageName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "init":
                toolkitReady = true
                loadMusicXMLIfNeeded()
            case "ready":
                pageReady = true
                parent.onReady?()
                // The page was rebuilt: send everything again.
                pushedSelectionValid = false
                pushedFlags = nil
                lastPushedBeat = nil
                lastPushWasClear = false
                pushSelection(parent.selection)
                pushFlags(parent.flaggedMeasures)
                pushHighlight(parent.highlightBeat)
            case "tapNote":
                let measureIndex = (body["measureIndex"] as? NSNumber)?.intValue ?? -1
                let measureNumber = (body["measureN"] as? String) ?? ""
                let noteOrder = (body["noteOrder"] as? NSNumber)?.intValue ?? -1
                let qstamp = (body["qstamp"] as? NSNumber)?.doubleValue ?? 0
                parent.onTapNote?(EditorNoteTap(measureIndex: measureIndex, measureNumber: measureNumber,
                                                noteOrder: noteOrder, qstamp: qstamp))
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

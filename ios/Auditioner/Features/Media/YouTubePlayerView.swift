import SwiftUI
import UIKit
import WebKit

// YouTube's official IFrame player in a WKWebView, following YouTube's Required Minimum
// Functionality: the official embed, full size, nothing drawn on top, no autoplay, inline
// playback, and any link the user taps opens in Safari. Audio/video is never touched.

/// Builds the host page. Pure, so it is unit-tested.
enum YouTubePlayerHTML {
    static let messageHandlerName = "auditionerPlayer"
    static let pollIntervalMilliseconds = 250
    static let nocookieHost = "https://www.youtube-nocookie.com"
    static let iframeAPI = "https://www.youtube.com/iframe_api"

    /// "https://<bundle id, lowercased>" — the page origin the IFrame API is told about.
    static func origin(bundleIdentifier: String?) -> String {
        let id = (bundleIdentifier ?? "com.milaiwalker.auditioner").lowercased()
        return "https://" + id
    }

    /// Keeps only the characters a YouTube video id can contain.
    static func sanitizedVideoId(_ raw: String) -> String {
        String(raw.filter { ch in ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") })
    }

    static func sanitizedOrigin(_ raw: String) -> String {
        String(raw.filter { ch in ch != "'" && ch != "\"" && ch != "\\" && ch != "<" && ch != ">" && ch != "\n" })
    }

    /// The `playerVars` object: start/end only when known (verified), never autoplay.
    static func playerVars(startSeconds: Int?, endSeconds: Int?, origin: String) -> String {
        var vars: [String] = ["playsinline: 1", "rel: 0"]
        if let start = startSeconds, start >= 0 {
            vars.append("start: \(start)")
        }
        if let end = endSeconds, end > 0 {
            vars.append("end: \(end)")
        }
        vars.append("origin: '\(sanitizedOrigin(origin))'")
        return "{ " + vars.joined(separator: ", ") + " }"
    }

    static func build(videoId: String, startSeconds: Int?, endSeconds: Int?, origin: String) -> String {
        let id = sanitizedVideoId(videoId)
        let vars = playerVars(startSeconds: startSeconds, endSeconds: endSeconds, origin: origin)
        let handler = messageHandlerName
        let poll = pollIntervalMilliseconds
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        html, body { margin: 0; padding: 0; background: #000; width: 100%; height: 100%; overflow: hidden; }
        #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script>
        var player = null;
        var pollTimer = null;
        function post(message) {
          try { window.webkit.messageHandlers.\(handler).postMessage(message); } catch (e) {}
        }
        function getRates() {
          if (player && typeof player.getAvailablePlaybackRates === 'function') {
            return player.getAvailablePlaybackRates();
          }
          return [1];
        }
        function seekTo(seconds) { if (player) { player.seekTo(seconds, true); } }
        function play() { if (player) { player.playVideo(); } }
        function pause() { if (player) { player.pauseVideo(); } }
        function setRate(rate) { if (player) { player.setPlaybackRate(rate); } }
        function startPolling() {
          if (pollTimer) { return; }
          pollTimer = setInterval(function () {
            if (player && typeof player.getCurrentTime === 'function') {
              post({ type: 'time', t: player.getCurrentTime() });
            }
          }, \(poll));
        }
        function onPlayerReady(event) {
          post({ type: 'ready', rates: getRates() });
          startPolling();
        }
        function onPlayerStateChange(event) { post({ type: 'state', state: event.data }); }
        function onPlayerError(event) { post({ type: 'error', code: event.data }); }
        function onPlaybackRateChange(event) { post({ type: 'rate', rate: event.data }); }
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            host: '\(nocookieHost)',
            videoId: '\(id)',
            width: '100%',
            height: '100%',
            playerVars: \(vars),
            events: {
              onReady: onPlayerReady,
              onStateChange: onPlayerStateChange,
              onError: onPlayerError,
              onPlaybackRateChange: onPlaybackRateChange
            }
          });
        }
        var tag = document.createElement('script');
        tag.src = '\(iframeAPI)';
        tag.onerror = function () { post({ type: 'error', code: -1 }); };
        document.head.appendChild(tag);
        </script>
        </body>
        </html>
        """
    }
}

/// What the navigation delegate does with a request.
enum YouTubeNavigationDecision: Equatable {
    case allow
    case block
    case openExternally
}

/// Pure policy for the web view: only the initial page and YouTube's own frames load inside;
/// anything the user taps goes to Safari. Unit-tested.
enum YouTubeNavigationPolicy {
    static let allowedFrameHosts: [String] = [
        "youtube.com", "youtube-nocookie.com", "ytimg.com", "googlevideo.com",
        "google.com", "googleapis.com", "gstatic.com", "ggpht.com",
        "doubleclick.net", "googlesyndication.com", "googleadservices.com"
    ]

    static func isAllowedFrameHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return allowedFrameHosts.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }

    static func decide(url: URL, isLinkActivated: Bool, isMainFrame: Bool, hasTargetFrame: Bool,
                       baseHost: String?) -> YouTubeNavigationDecision {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "about" { return .allow }
        let isWeb = scheme == "http" || scheme == "https"
        if isLinkActivated || !hasTargetFrame {
            return isWeb ? .openExternally : .block
        }
        let host = (url.host ?? "").lowercased()
        if isMainFrame {
            if let base = baseHost?.lowercased(), !base.isEmpty, host == base { return .allow }
            return .block
        }
        return isAllowedFrameHost(host) ? .allow : .block
    }
}

/// Plain-words text for an IFrame API error code (YouTube documents 2, 5, 100, 101, 150).
enum YouTubeErrorText {
    static func message(code: Int) -> String {
        switch code {
        case -1:
            return String(localized: "The YouTube player couldn't load. Check your connection and try again.")
        case 2:
            return String(localized: "This video link looks wrong (YouTube error 2).")
        case 5:
            return String(localized: "YouTube couldn't play this video here (error 5).")
        case 100:
            return String(localized: "This video has been removed or made private (YouTube error 100).")
        case 101, 150:
            return String(localized: "The owner doesn't allow this video to play inside other apps.")
        case 153:
            return String(localized: "YouTube refused to play this video inside the app (error 153).")
        default:
            return String(localized: "YouTube couldn't play this video here (error \(code)).")
        }
    }
}

/// State of the embedded player, fed by the page's messages. One per player on screen.
final class YouTubePlayerController: ObservableObject {
    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var availableRates: [Double] = [1]
    @Published private(set) var currentRate: Double = 1
    /// YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
    @Published private(set) var stateCode: Int = -1
    @Published private(set) var errorCode: Int? = nil
    @Published private(set) var loadFailure: String? = nil
    /// True once the video has played at least once (the user tapped play in the video).
    @Published private(set) var hasPlayed: Bool = false

    weak var webView: WKWebView?

    var isPlaying: Bool {
        stateCode == 1 || stateCode == 3
    }

    func handle(messageBody: Any) {
        guard let body = messageBody as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            if let rates = body["rates"] as? [Double], !rates.isEmpty {
                availableRates = rates.sorted()
            }
        case "time":
            if let t = body["t"] as? Double, t.isFinite {
                currentTime = max(0, t)
            }
        case "state":
            if let state = body["state"] as? Int {
                stateCode = state
                if state == 1 { hasPlayed = true }
            }
        case "error":
            if let code = body["code"] as? Int {
                errorCode = code
            }
        case "rate":
            if let rate = body["rate"] as? Double, rate > 0 {
                currentRate = rate
            }
        default:
            break
        }
    }

    func reportLoadFailure(_ error: Error) {
        loadFailure = error.localizedDescription
    }

    func seek(to seconds: Double) {
        run("seekTo(\(jsNumber(seconds)));")
    }

    func play() {
        run("play();")
    }

    func pause() {
        run("pause();")
    }

    func setRate(_ rate: Double) {
        currentRate = rate
        run("setRate(\(jsNumber(rate)));")
    }

    private func jsNumber(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        return String(format: "%.3f", safe)
    }

    private func run(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}

/// Forwards script messages to a weakly held target so the WKUserContentController
/// (which retains its handlers) does not keep the coordinator alive.
final class YouTubeScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// The embedded player. Give it the full width, 16:9 and at least 200 pt; draw nothing on top.
struct YouTubePlayerView: UIViewRepresentable {
    let videoId: String
    /// Verified start, already moved 1 s early by the caller when wanted. `nil` = unknown.
    let startSeconds: Int?
    let endSeconds: Int?
    let controller: YouTubePlayerController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsPictureInPictureMediaPlayback = false
        let contentController = WKUserContentController()
        contentController.add(YouTubeScriptMessageProxy(target: context.coordinator), name: YouTubePlayerHTML.messageHandlerName)
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = true
        webView.backgroundColor = UIColor.black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        let origin = YouTubePlayerHTML.origin(bundleIdentifier: Bundle.main.bundleIdentifier)
        let baseURL = URL(string: origin)
        context.coordinator.baseHost = baseURL?.host
        controller.webView = webView
        let html = YouTubePlayerHTML.build(videoId: videoId, startSeconds: startSeconds, endSeconds: endSeconds, origin: origin)
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The video is fixed for the life of the view; use `.id(...)` to show another one.
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: YouTubePlayerHTML.messageHandlerName)
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
        coordinator.controller.webView = nil
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let controller: YouTubePlayerController
        var baseHost: String?

        init(controller: YouTubePlayerController) {
            self.controller = controller
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == YouTubePlayerHTML.messageHandlerName else { return }
            controller.handle(messageBody: message.body)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let decision = YouTubeNavigationPolicy.decide(
                url: url,
                isLinkActivated: navigationAction.navigationType == .linkActivated,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                hasTargetFrame: navigationAction.targetFrame != nil,
                baseHost: baseHost
            )
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .block:
                decisionHandler(.cancel)
            case .openExternally:
                Coordinator.openExternally(url)
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                Coordinator.openExternally(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            controller.reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            controller.reportLoadFailure(error)
        }

        /// Opens a user-tapped link (YouTube logo, title, "Watch on YouTube") in Safari.
        static func openExternally(_ url: URL) {
            let scheme = (url.scheme ?? "").lowercased()
            guard scheme == "http" || scheme == "https" else { return }
            Task { @MainActor in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }
}

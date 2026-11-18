// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
import WebKit

/// Plays a YouTube video with YouTube's own embedded player (the IFrame Player API) in a web view.
/// The player is shown on the Now Playing screen, as YouTube requires of embedded players, with its
/// ads. Nothing is extracted from YouTube: the video is only ever played by YouTube's player.
@MainActor
final class YouTubePlayer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView

    var onUpdate: (() -> Void)?
    var onEnded: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var durationMs: Int64 = 0
    private var lastTimeMs: Int64 = 0
    private var lastStamp = Date()
    private var ready = false
    private var pending: String?
    private var pageLoaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
        super.init()
        controller.add(self, name: "yt")
        webView.navigationDelegate = self
    }

    var positionMs: Int64 {
        guard isPlaying else { return lastTimeMs }
        return lastTimeMs + Int64(Date().timeIntervalSince(lastStamp) * 1000)
    }

    // MARK: Commands

    func play(videoID: String) {
        isBuffering = true
        isPlaying = false
        lastTimeMs = 0
        lastStamp = Date()
        durationMs = 0
        if !pageLoaded {
            pageLoaded = true
            webView.loadHTMLString(YouTubePlayer.page, baseURL: URL(string: "https://www.youtube.com"))
        }
        if ready { run("loadVideo('\(videoID)')") } else { pending = videoID }
        onUpdate?()
    }

    func resume() { run("player.playVideo()"); isPlaying = true; lastStamp = Date(); onUpdate?() }
    func pause() { run("player.pauseVideo()"); lastTimeMs = positionMs; isPlaying = false; onUpdate?() }

    func seek(toMs ms: Int64) {
        run("player.seekTo(\(Double(Swift.max(0, ms)) / 1000), true)")
        lastTimeMs = ms
        lastStamp = Date()
        onUpdate?()
    }

    func stop() {
        pending = nil
        if ready { run("player.stopVideo()") }
        isPlaying = false
        isBuffering = false
        onUpdate?()
    }

    private func run(_ js: String) {
        guard ready || js.hasPrefix("loadVideo") else { return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Events from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            if let id = pending {
                pending = nil
                run("loadVideo('\(id)')")
            }
        case "state":
            let state = (body["state"] as? NSNumber)?.intValue ?? -1
            switch state {
            case 1:
                isPlaying = true
                isBuffering = false
                lastStamp = Date()
            case 2:
                lastTimeMs = positionMs
                isPlaying = false
                isBuffering = false
            case 3:
                isBuffering = true
            case 0:
                isPlaying = false
                isBuffering = false
                onEnded?()
            default:
                break
            }
            onUpdate?()
        case "time":
            if let t = (body["t"] as? NSNumber)?.doubleValue, t.isFinite {
                lastTimeMs = Int64(t * 1000)
                lastStamp = Date()
            }
            if let d = (body["d"] as? NSNumber)?.doubleValue, d.isFinite, d > 0 { durationMs = Int64(d * 1000) }
        case "error":
            let code = (body["code"] as? NSNumber)?.intValue ?? 0
            isPlaying = false
            isBuffering = false
            let text = (code == 101 || code == 150)
                ? "The owner of this YouTube video does not allow it to play in other apps."
                : (code == 100 ? "This YouTube video is no longer available." : "YouTube could not play this video (error \(code)).")
            onFailed?(text)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoaded = false
        onFailed?("YouTube's player did not load: \(error.localizedDescription)")
    }

    // MARK: The embedded player page

    static let page = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
      html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
      #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
    </style>
    </head>
    <body>
    <div id="player"></div>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
      var player = null;
      var ready = false;
      var queued = null;
      function post(o) { try { window.webkit.messageHandlers.yt.postMessage(o); } catch (e) {} }
      function onYouTubeIframeAPIReady() {
        player = new YT.Player('player', {
          width: '100%', height: '100%',
          playerVars: { playsinline: 1, controls: 1, rel: 0, modestbranding: 1, fs: 0, origin: 'https://www.youtube.com' },
          events: {
            onReady: function () { ready = true; post({ type: 'ready' }); if (queued) { loadVideo(queued); queued = null; } },
            onStateChange: function (e) { post({ type: 'state', state: e.data }); },
            onError: function (e) { post({ type: 'error', code: e.data }); }
          }
        });
      }
      function loadVideo(id) {
        if (!ready) { queued = id; return; }
        player.loadVideoById(id);
      }
      setInterval(function () {
        if (ready && player && player.getCurrentTime) {
          post({ type: 'time', t: player.getCurrentTime(), d: player.getDuration(), s: player.getPlayerState() });
        }
      }, 500);
    </script>
    </body>
    </html>
    """
}

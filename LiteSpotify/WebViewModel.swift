import SwiftUI
import WebKit

class WebViewModel: ObservableObject {
    let webView: WKWebView
    @Published var isLoggedOut: Bool = false
    @Published var currentTitle: String = "Spotify"
    @Published var isPlaying: Bool = false
    
    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Use a persistent data store so login is saved
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.isOpaque = false
        self.webView.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0)
        
        loadSpotify()
    }
    
    func loadSpotify() {
        if let url = URL(string: "https://open.spotify.com") {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    
    func reload() {
        webView.reload()
    }
}

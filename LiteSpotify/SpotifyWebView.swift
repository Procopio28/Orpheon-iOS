import SwiftUI
import WebKit

struct SpotifyWebView: UIViewRepresentable {
    @ObservedObject var webModel: WebViewModel
    
    func makeUIView(context: Context) -> WKWebView {
        webModel.webView.navigationDelegate = context.coordinator
        return webModel.webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SpotifyWebView
        
        init(_ parent: SpotifyWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let title = webView.title {
                parent.webModel.currentTitle = title
            }
        }
    }
}

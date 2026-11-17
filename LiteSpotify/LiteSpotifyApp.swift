import SwiftUI

@main
struct LiteSpotifyApp: App {
    @StateObject private var webModel = WebViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(webModel)
                .preferredColorScheme(.dark)
        }
    }
}

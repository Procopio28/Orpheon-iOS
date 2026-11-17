import SwiftUI

struct ContentView: View {
    @EnvironmentObject var webModel: WebViewModel
    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Main Tab View styled like Spotify
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Image(systemName: "house.fill")
                        Text("Home")
                    }
                    .tag(0)
                
                SearchView()
                    .tabItem {
                        Image(systemName: "magnifyingglass")
                        Text("Search")
                    }
                    .tag(1)
                
                LibraryView()
                    .tabItem {
                        Image(systemName: "books.vertical.fill")
                        Text("Library")
                    }
                    .tag(2)
            }
            .accentColor(.white)
            
            // Persistent Mini Player Bar above TabBar
            VStack(spacing: 0) {
                Button(action: { showFullPlayer = true }) {
                    HStack(spacing: 12) {
                        ZStack {
                            Color.green.opacity(0.3)
                            Image(systemName: "music.note")
                                .foregroundColor(.green)
                        }
                        .frame(width: 40, height: 40)
                        .cornerRadius(4)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(webModel.currentTitle.isEmpty ? "Tap to open Spotify Player" : webModel.currentTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text("Tap here to log in & play audio")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            showFullPlayer = true
                        }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                        }
                        .padding(.trailing, 8)
                        
                        Image(systemName: "heart")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    }
                    .padding(8)
                    .background(Color(#colorLiteral(red: 0.1607843137, green: 0.1607843137, blue: 0.1607843137, alpha: 1)))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }
                .padding(.bottom, 49) // Height of standard tab bar
            }
        }
        .sheet(isPresented: $showFullPlayer) {
            WebPlayerModalView(webModel: webModel)
        }
    }
}

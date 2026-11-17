import SwiftUI

struct SearchView: View {
    @EnvironmentObject var webModel: WebViewModel
    @State private var searchText = ""
    @State private var showWeb = false
    
    let genres = [
        ("Pop", Color.pink),
        ("Hip-Hop", Color.orange),
        ("Rock", Color.red),
        ("Indie", Color.indigo),
        ("Podcasts", Color.purple),
        ("Electronic", Color.blue),
        ("R&B", Color.teal),
        ("Classical", Color.brown)
    ]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("Search")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    
                    // Search bar mockup
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        TextField("Artists, songs, or podcasts", text: $searchText)
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    
                    Text("Browse all")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(genres, id: \.0) { genre in
                                Button(action: { showWeb = true }) {
                                    ZStack(alignment: .topLeading) {
                                        genre.1
                                            .cornerRadius(6)
                                        Text(genre.0)
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(12)
                                    }
                                    .frame(height: 100)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showWeb) {
                WebPlayerModalView(webModel: webModel)
            }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var webModel: WebViewModel
    @State private var showWeb = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Your Library")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: { showWeb = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    
                    // Filter Chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["Playlists", "Artists", "Albums", "Podcasts"], id: \.self) { filter in
                                Button(action: { showWeb = true }) {
                                    Text(filter)
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(0.1))
                                        .foregroundColor(.white)
                                        .cornerRadius(20)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    List {
                        ForEach(1..<6, id: \.self) { i in
                            Button(action: { showWeb = true }) {
                                HStack(spacing: 12) {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 56, height: 56)
                                        .cornerRadius(4)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Saved Playlist #\(i)")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text("Playlist • User • 24 songs")
                                            .font(.system(size: 13))
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showWeb) {
                WebPlayerModalView(webModel: webModel)
            }
        }
    }
}

struct WebPlayerModalView: View {
    @ObservedObject var webModel: WebViewModel
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Custom top bar with reload and close
                    HStack {
                        Button(action: { webModel.reload() }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.white)
                                .font(.system(size: 18))
                        }
                        Spacer()
                        Text("Spotify Web Player")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.gray)
                        Spacer()
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 22))
                        }
                    }
                    .padding()
                    .background(Color.black)
                    
                    SpotifyWebView(webModel: webModel)
                        .edgesIgnoringSafeArea(.bottom)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var webModel: WebViewModel
    @State private var showWebPlayer = false
    
    let quickAccessItems = [
        ("Liked Songs", "heart.fill", Color.purple),
        ("Today's Top Hits", "flame.fill", Color.pink),
        ("Discover Weekly", "sparkles", Color.blue),
        ("Daily Mix 1", "music.note.list", Color.green),
        ("Release Radar", "antenna.radiowaves.left.and.right", Color.orange),
        ("Lo-Fi Beats", "moon.stars.fill", Color.indigo)
    ]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.07)
                    .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        HStack {
                            Text("Good afternoon")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: {
                                showWebPlayer = true
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "globe")
                                    Text("Web Login")
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(#colorLiteral(red: 0.1137254902, green: 0.7254901961, blue: 0.3294117647, alpha: 1)))
                                .foregroundColor(.black)
                                .cornerRadius(16)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        
                        // Quick Access Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(quickAccessItems, id: \.0) { item in
                                Button(action: {
                                    showWebPlayer = true
                                }) {
                                    HStack(spacing: 10) {
                                        ZStack {
                                            item.2
                                            Image(systemName: item.1)
                                                .foregroundColor(.white)
                                                .font(.system(size: 16))
                                        }
                                        .frame(width: 56, height: 56)
                                        .cornerRadius(4)
                                        
                                        Text(item.0)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.white)
                                            .lineLimit(2)
                                        
                                        Spacer()
                                    }
                                    .background(Color(red: 0.16, green: 0.16, blue: 0.16))
                                    .cornerRadius(6)
                                    .clipped()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        // Section: Recently Played
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recently Played")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(1..<6, id: \.self) { i in
                                        Button(action: { showWebPlayer = true }) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ZStack {
                                                    LinearGradient(colors: [Color.gray.opacity(0.3), Color.black], startPoint: .top, endPoint: .bottom)
                                                    Image(systemName: "music.note")
                                                        .font(.system(size: 32))
                                                        .foregroundColor(.white.opacity(0.7))
                                                }
                                                .frame(width: 140, height: 140)
                                                .cornerRadius(8)
                                                
                                                Text("Playlist Mix #\(i)")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                
                                                Text("By Spotify")
                                                    .font(.system(size: 12, weight: .regular))
                                                    .foregroundColor(.gray)
                                            }
                                            .frame(width: 140)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 10)
                        
                        // Section: Made For You
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Made For You")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(1..<5, id: \.self) { i in
                                        Button(action: { showWebPlayer = true }) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ZStack {
                                                    Color.green.opacity(0.3)
                                                    Image(systemName: "headphones")
                                                        .font(.system(size: 32))
                                                        .foregroundColor(.green)
                                                }
                                                .frame(width: 140, height: 140)
                                                .cornerRadius(8)
                                                
                                                Text("Daily Mix \(i)")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                
                                                Text("Your personal rotation")
                                                    .font(.system(size: 12, weight: .regular))
                                                    .foregroundColor(.gray)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 140)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 10)
                        
                        Spacer().frame(height: 100)
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showWebPlayer) {
                WebPlayerModalView(webModel: webModel)
            }
        }
    }
}

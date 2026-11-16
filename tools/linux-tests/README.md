Logic tests that run on Linux (Swift 5.9+), without Xcode:

    S=Orpheon
    swiftc -o /tmp/orph-tests tools/linux-tests/main.swift $S/Core/*.swift $S/App/Route.swift \
      $S/Spotify/{Gql,Mappers,SpotifyBrowse,SpotifyHTTP,SpotifyLibrary,SpotifyService,Storage}.swift \
      $S/Playback/ConnectAPI.swift $S/Lyrics/LyricsService.swift && /tmp/orph-tests

(`main.swift` reads the operation table from an absolute path; adjust it for your checkout.)

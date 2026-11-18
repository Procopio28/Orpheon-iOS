Logic tests that run on Linux (Swift 5.9+), without Xcode. `main.swift` and `sources-tests.swift`
are two separate programs (copy the one you want to run to a file called `main.swift`):

    S=Orpheon
    # data layer: JSON paths, mappers, sorting, LRC, Spotify Connect state, stubbed HTTP + GraphQL
    swiftc -o /tmp/orph-tests tools/linux-tests/main.swift $S/Core/*.swift $S/App/Route.swift \
      $S/Spotify/{Gql,Mappers,SpotifyBrowse,SpotifyHTTP,SpotifyLibrary,SpotifyService,Storage}.swift \
      $S/Playback/ConnectAPI.swift $S/Lyrics/LyricsService.swift && /tmp/orph-tests

    # source layer: matcher, Apple Music / YouTube / Audius providers (stubbed), queue, resolver
    cp tools/linux-tests/sources-tests.swift /tmp/main.swift
    swiftc -o /tmp/orph-sources /tmp/main.swift $S/Core/*.swift $S/Sources/*.swift && /tmp/orph-sources

(Both read files relative to the project root; run them from there.)

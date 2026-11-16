# What is ported, what is not

Source: [Orpheon](https://github.com/kota-zo/Orpheon), ~157k lines of Kotlin (Android). This port is
~7k lines of Swift. It is the part of Orpheon that can exist on iOS, written to match the original's
requests and mappers.

## The one thing that cannot be ported: Spotify audio inside the app

Spotify delivers audio only as **Widevine-encrypted** files (its Web Player and Orpheon's own
"native engine" both ask a Widevine CDM for the keys). Android has that CDM. **iOS does not**:
`WKWebView` has no encrypted-media support, and Spotify offers no FairPlay version of this audio.
The only way around it would be to defeat the DRM, which this port does not do.

So everything that *needs the decoded Spotify audio* is out: the equalizer, crossfade, loudness
normalisation, skip-silence, stats for nerds, offline downloads of Spotify tracks, ad muting and
ad blocking (also against Spotify's terms), Spotify Connect *as a speaker* (this phone playing for
other devices), Jam, and Orpheon's own shuffle/mix engines. Anything built on the in-app engine goes
with it.

## Ported, same behaviour

| Orpheon | iOS port |
|---|---|
| Sign in on Spotify's own page, session kept as `sp_dc` | Yes (`WKWebView` login, or paste the cookie) |
| Web token minted by the Web Player page | Yes (hidden `WKWebView` runs the page; same service lookup as Orpheon's bridge) |
| Client token, persisted-query GraphQL (179 operations), auto-refresh of the operation table when Spotify ships a new build | Yes |
| Home feed with Music / Podcasts / Audiobooks filters | Yes |
| Search: all, songs, artists, albums, playlists, podcasts; recent searches; browse categories | Yes |
| Your Library: filters, sort, folders, pins, Liked Songs | Yes (pin/unpin is in the API layer, no button yet) |
| Album, artist (top tracks, releases, appears on, related, bio), playlist, user profile, show, episode, audiobook pages | Yes |
| Playlists: create, rename, add, remove, sort, follow/unfollow, delete | Yes |
| Like/unlike, follow artists/users, save shows | Yes |
| Lyrics: Spotify's own (line synced, word synced where present, colours parsed) with LRCLIB fallback | Yes |
| Live radio (radio-browser.info) | Yes, plays in the app with lock-screen controls and background audio |
| Local audio files (from the Files app) | Yes (tags and cover art read, plays in the app) |
| Podcast episodes | Plays **in the app** when Spotify exposes the publisher's own file (speed control 1x to 2x); otherwise through Spotify |

## Ported, but different

| Orpheon | iOS port |
|---|---|
| In-app playback of Spotify music | **Spotify Connect remote control**: the official Spotify app (this phone, a speaker, a computer) plays; this app commands it and mirrors its state (play/pause, seek, next/previous, shuffle, repeat, volume, queue view/add, transfer between devices). Spotify only allows this for **Premium**. |
| "A Free account is enough" | Not on iOS. With Free, a tap opens the song in the Spotify app. |
| Queue editing (reorder, remove, play next) | View and add-to-queue only: Spotify's Web API offers no more. |
| Free-form device picker on the Web Player | Connect devices list + transfer. |

## Not ported: possible, not done in this pass

* **Extensions (JavaScript plugins)**: portable with JavaScriptCore, but the host API is large
  (~9k lines of Kotlin). Lyrics sources, home sections and menu entries could be ported; *audio and
  download sources are not wanted here*.
* Genius song meanings, Spotify Codes, collaborative-playlist invites, playlist cover upload,
  Listening Recap and local statistics, "What's new" feed (the API call exists, no screen),
  top artists/tracks (API exists, no screen), track credits (API exists, no screen).
* **CarPlay** (needs Apple's CarPlay entitlement; with a jailbreak you can add it when signing),
  Home-screen widgets, Siri/Shortcuts, Live Activities.
* The Android-only parts: Wear OS, Android Auto, Android TV, Cast, Quick Settings tile, Material You.

## Honest limits of what I could check

I had no Xcode and no iPhone in my environment. What I did:

* Wrote all 34 Swift files and **typechecked each file** against stand-ins for SwiftUI, WebKit,
  AVFoundation, MediaPlayer, UIKit and Combine (the stand-ins model the iOS 15 API surface and the
  strict main-actor rules of older SDKs, so it should also build on Xcode 15, 16 and later).
* **Ran** the logic on Linux with tests: JSON paths, every mapper, sorting, LRC parsing, Spotify
  Connect state mapping, and the HTTP + GraphQL stack against a stubbed network (headers, token
  reuse, error handling). `tools/linux-tests/` holds them.
* Validated `project.pbxproj` with a real pbxproj parser (all references resolve).

Not verified, so expect to touch these first if something misbehaves:

1. **The token bridge** depends on Spotify's page: it loads open.spotify.com in a `WKWebView` and
   reads the token from the page (and from its `/api/token` request as a fallback). If Spotify
   changes its page, this is where it breaks.
2. **Connect remote control** uses Spotify's public Web API with the Web Player token. It is
   Premium-only and rate-limited; the app polls gently (3 s while playing).
3. Compiler differences between the real Apple SDKs and my stand-ins: expect at most small fixes.
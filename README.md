# Orpheon for iOS

An iOS port of [Orpheon](https://github.com/kota-zo/Orpheon) (the Android Spotify client), written in
SwiftUI with no third-party dependencies. Made for personal use on a jailbroken device.

* iOS 15.0 or newer, iPhone and iPad. Xcode 14 or newer to build (tested layout for Xcode 15/16/26).
* No Swift packages, no CocoaPods.

## Build

```bash
open Orpheon.xcodeproj          # then Product > Build for "Any iOS Device (arm64)"
# or, headless, producing an unsigned (and, if ldid is installed, fake-signed) IPA:
./build_ipa.sh
```

Signing is disabled in the project on purpose (you fake-sign). To run from Xcode on a device with a
normal developer account, select the target, *Signing & Capabilities*, and pick your team.

After adding or removing Swift files, run `python3 tools/gen_xcodeproj.py` to regenerate
`Orpheon.xcodeproj`.

## How it works, and the one big difference from Android

Orpheon on Android plays Spotify **inside the app**: it runs the official Web Player in a hidden
WebView, and the phone's Widevine DRM decrypts the audio. **iOS has no Widevine** (and `WKWebView`
has no encrypted-media support), and Spotify serves its audio only as Widevine-encrypted files.
So Spotify's audio cannot be decoded by this app, and this port does not try to get around that.

What the port does instead:

* **Browse and manage everything** exactly like Orpheon: home, search, library, playlists, albums,
  artists, podcasts, profiles, lyrics. These calls go straight to Spotify's servers (GraphQL
  persisted queries) with the Web Player's own token, minted by the Web Player page running in a
  hidden `WKWebView` signed in with your cookie.
* **Play through Spotify Connect**: the official Spotify app (on this phone, or a speaker/computer)
  decodes and plays; this app drives it (play, pause, seek, queue, shuffle, repeat, volume,
  transfer between devices) and mirrors its state. Spotify only allows remote control for
  **Premium** accounts; with a Free account, songs open in the Spotify app instead ("Open in Spotify").
  The Spotify app must be running (open it once) so it shows up as a device.
* **Play locally what iOS can decode**: live radio (radio-browser.info), and podcast episodes whose
  publisher file Spotify exposes. These get background audio, lock-screen controls and headset buttons.

* **Play Spotify songs from other sources** (Apple Music, YouTube, Audius, or all of them): pick it in
  Settings > Playback source. See `PORTING.md`.

See `PORTING.md` for the full list of what is ported, partly ported and not ported.

## Sign in

Tap **Sign in with Spotify**. The login page is Spotify's own; the app only ever sees the `sp_dc`
session cookie it sets. Social logins (Google/Facebook/Apple) are sometimes blocked inside web
views; if so, sign in at open.spotify.com in a browser, copy the `sp_dc` cookie value, and use
**I have an sp_dc cookie**.

## License

GPL-3.0, as a derivative of Orpheon. See `NOTICE.md` and `LICENSE`.

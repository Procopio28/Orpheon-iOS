# Orpheon for iOS: credits and license

This project is an **iOS port of [Orpheon](https://github.com/kota-zo/Orpheon)** (formerly *Myspoti*) by
kota-zo and contributors, which is licensed under the **GNU General Public License v3.0**.

The Swift code here is derived from Orpheon's Kotlin sources and documentation
(`docs/api/*`): the GraphQL operation table (`Orpheon/Resources/gql-ops.json`), the request
shapes, the response mappers, the page-bridge token lookup, the lyrics and radio providers.
Because it is a derivative work it is licensed under the same **GPL-3.0** (see `LICENSE`).

What that means in practice:

* Using, modifying and installing it **for yourself** on your own devices needs nothing else.
* If you ever give a build or the source to anyone else, you must keep these notices, name Orpheon
  as the origin, license your whole project under GPL-3.0 and make its complete source available
  to the people who receive it.

Unofficial and unaffiliated: this is not a Spotify product. Using Spotify's private web endpoints
may breach Spotify's Terms of Use; you use it at your own risk and with your own account.

Other things used:

* Radio directory: [radio-browser.info](https://www.radio-browser.info) (community API).
* Lyrics fallback: [LRCLIB](https://lrclib.net).
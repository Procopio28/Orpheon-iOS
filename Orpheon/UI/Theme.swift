// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let elevated = Color(red: 0.17, green: 0.17, blue: 0.17)
    static let accent = Color(red: 0.12, green: 0.84, blue: 0.38)
    static let secondary = Color(white: 1, opacity: 0.62)
    static let hairline = Color(white: 1, opacity: 0.12)
}

/// Where a remote request stands.
enum LoadState<T> {
    case loading
    case loaded(T)
    case failed(String)

    var value: T? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return error.localizedDescription
}

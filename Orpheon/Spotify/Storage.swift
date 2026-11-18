// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// A tiny persistent string store (one JSON file in Application Support). It holds the client
/// token, the last web token, the device id and a few settings. It is a plain file on purpose: an
/// app that is fake-signed on a jailbreak often has no keychain entitlement.
final class KeyValueStore {
    private let fileURL: URL
    private var values: [String: String]
    private let lock = NSLock()

    init(fileName: String = "store.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Orpheon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: fileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            values = dict
        } else {
            values = [:]
        }
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: String?) {
        lock.lock()
        if let value = value, !value.isEmpty { values[key] = value } else { values.removeValue(forKey: key) }
        let snapshot = values
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func bool(_ key: String, default def: Bool = false) -> Bool {
        guard let v = get(key) else { return def }
        return v == "1"
    }

    func setBool(_ key: String, _ value: Bool) { set(key, value ? "1" : "0") }

    func clear() {
        lock.lock()
        values.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The directory the app keeps its own files in.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Orpheon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

import AppKit
import DancefloorCore
import os

private let log = Logger(subsystem: "com.natesute.dancefloor", category: "library")

/// Where a dancer's GIF came from, so it can be restored on relaunch.
enum GifSource: Codable, Equatable {
    case local(path: String)
    case giphy(id: String, url: String)

    var key: String {
        switch self {
        case .local(let path): "local:" + (path as NSString).lastPathComponent
        case .giphy(let id, _): "giphy:" + id
        }
    }

    static func == (a: GifSource, b: GifSource) -> Bool { a.key == b.key }

    var isGiphy: Bool { if case .giphy = self { true } else { false } }
}

struct LoadedGif {
    let source: GifSource
    let title: String
    let data: Data
    let animation: GIFAnimation
    /// The search that found it, so the swap strip can offer more like it.
    let term: String?
}

/// Something shown in the picker grid or swap strip, before its full GIF is downloaded.
struct PickerItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case giphy(id: String, url: URL)
        case local(path: String)
    }

    let id: String
    let title: String
    let previewURL: URL
    let kind: Kind
    let term: String?

    var source: GifSource {
        switch kind {
        case .giphy(let id, let url): .giphy(id: id, url: url.absoluteString)
        case .local(let path): .local(path: path)
        }
    }
}

enum SourceMode: String, CaseIterable {
    case both, giphy, local

    var title: String {
        switch self {
        case .both: "GIPHY + folder"
        case .giphy: "GIPHY"
        case .local: "My folder"
        }
    }
}

@MainActor
final class GifLibrary {
    enum Failure: LocalizedError {
        case nothingToPick, noResults(String), unreadable
        var errorDescription: String? {
            switch self {
            case .nothingToPick: "No GIFs available. Add some to your Dancefloor folder, or set a GIPHY API key."
            case .noResults(let q): "GIPHY had nothing for \"\(q)\"."
            case .unreadable: "That file isn't a readable GIF."
            }
        }
    }

    static let defaultTerms = [
        "dancing", "dance", "twerk", "shrek dance", "dancing cat", "dancing dog", "dance party",
        "dancing animal", "breakdance", "dancing baby", "dancing frog", "dancing banana", "vibing",
    ]

    let folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Dancefloor", isDirectory: true)
    private let defaults = UserDefaults.standard
    private var searchCache: [String: [GiphyClient.Gif]] = [:]

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var giphyKey: String? {
        get { defaults.string(forKey: "giphyAPIKey").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "giphyAPIKey"); searchCache.removeAll() }
    }

    /// Search terms Randomise and Add Dancer pick from. Setting an empty list restores the defaults.
    var randomTerms: [String] {
        get { defaults.stringArray(forKey: "randomTerms").flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTerms }
        set { defaults.set(newValue.isEmpty ? nil : newValue, forKey: "randomTerms") }
    }

    var mode: SourceMode {
        get { defaults.string(forKey: "sourceMode").flatMap(SourceMode.init) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "sourceMode") }
    }

    func localFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gif" }
    }

    // MARK: - Picking GIFs

    /// GIPHY results for a search, stickers first, falling back to regular GIFs. Cached per session
    /// because beta keys only allow about 100 searches an hour.
    func giphyItems(for query: String) async throws -> [PickerItem] {
        guard let key = giphyKey else { throw Failure.nothingToPick }
        let client = GiphyClient(apiKey: key)
        for kind in [GiphyClient.Kind.stickers, .gifs] {
            let cacheKey = "\(kind.rawValue):\(query.lowercased())"
            var results = searchCache[cacheKey]
            if results == nil {
                results = try await client.search(query, kind: kind)
                searchCache[cacheKey] = results
                log.info("GIPHY \(kind.rawValue, privacy: .public) '\(query, privacy: .public)': \(results?.count ?? 0) results")
            }
            let items = (results ?? []).compactMap { gif -> PickerItem? in
                guard let full = gif.downloadURL, let preview = gif.previewURL else { return nil }
                return PickerItem(id: "giphy:" + gif.id, title: gif.title.isEmpty ? query : gif.title,
                                  previewURL: preview, kind: .giphy(id: gif.id, url: full), term: query)
            }
            if !items.isEmpty { return items }
        }
        throw Failure.noResults(query)
    }

    func localItems() -> [PickerItem] {
        localFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            PickerItem(id: "local:" + $0.path, title: $0.deletingPathExtension().lastPathComponent,
                       previewURL: $0, kind: .local(path: $0.path), term: nil)
        }
    }

    func load(_ item: PickerItem) async throws -> LoadedGif {
        switch item.kind {
        case .local(let path):
            return try loadLocal(.local(path: path), title: item.title)
        case .giphy(let id, let url):
            let data = try await GiphyClient(apiKey: giphyKey ?? "").download(url)
            guard let animation = GIFAnimation(data: data) else { throw Failure.unreadable }
            return LoadedGif(source: .giphy(id: id, url: url.absoluteString), title: item.title, data: data,
                             animation: animation, term: item.term)
        }
    }

    func random(excluding current: GifSource? = nil) async throws -> LoadedGif {
        let pool = try await candidates(term: randomTerms.randomElement() ?? "dancing")
            .filter { $0.source != current }
        guard let pick = pool.randomElement() else { throw Failure.nothingToPick }
        return try await load(pick)
    }

    /// A handful of alternatives for the swap strip: more from the same search, or from the
    /// folder and a random search for local dancers.
    func alternatives(for gif: LoadedGif, count: Int = 4) async throws -> [PickerItem] {
        let pool = try await candidates(term: gif.term ?? randomTerms.randomElement() ?? "dancing")
        return Array(pool.filter { $0.source != gif.source }.shuffled().prefix(count))
    }

    /// Everything the current source mode allows for a term.
    private func candidates(term: String) async throws -> [PickerItem] {
        var pool: [PickerItem] = []
        if mode != .giphy { pool += localItems() }
        if mode != .local, giphyKey != nil {
            do { pool += try await giphyItems(for: term) } catch where !pool.isEmpty {
                log.error("GIPHY failed, using folder only: \(error.localizedDescription, privacy: .public)")
            }
        }
        if pool.isEmpty { throw Failure.nothingToPick }
        return pool
    }

    /// Reload a saved dancer's GIF.
    func load(_ source: GifSource, title: String, term: String?) async throws -> LoadedGif {
        switch source {
        case .local:
            return try loadLocal(source, title: title)
        case .giphy(_, let url):
            let data = try await GiphyClient(apiKey: giphyKey ?? "").download(URL(string: url)!)
            guard let animation = GIFAnimation(data: data) else { throw Failure.unreadable }
            return LoadedGif(source: source, title: title, data: data, animation: animation, term: term)
        }
    }

    func loadLocal(_ source: GifSource, title: String) throws -> LoadedGif {
        guard case .local(let path) = source,
              let data = FileManager.default.contents(atPath: path),
              let animation = GIFAnimation(data: data) else { throw Failure.unreadable }
        return LoadedGif(source: source, title: title, data: data, animation: animation, term: nil)
    }

    /// Save a GIPHY dancer into the local folder so it's always available.
    @discardableResult
    func keep(_ gif: LoadedGif) throws -> URL {
        let safe = gif.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
            .trimmingCharacters(in: .whitespaces)
        var url = folder.appendingPathComponent((safe.isEmpty ? "dancer" : String(safe.prefix(60))) + ".gif")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safe.prefix(60)) \(n).gif")
            n += 1
        }
        try gif.data.write(to: url)
        // Carry the tuning over to the saved copy.
        let newKey = GifSource.local(path: url.path).key
        defaults.set(beatsPerLoop(for: gif), forKey: "beats." + newKey)
        defaults.set(beatShift(for: gif.source), forKey: "shift." + newKey)
        return url
    }

    // MARK: - Per-GIF tuning

    func beatsPerLoop(for gif: LoadedGif) -> Int {
        let saved = defaults.integer(forKey: "beats." + gif.source.key)
        return saved > 0 ? saved : gif.animation.guessedBeatsPerLoop
    }

    func setBeatsPerLoop(_ beats: Int, for source: GifSource) {
        defaults.set(beats, forKey: "beats." + source.key)
    }

    func beatShift(for source: GifSource) -> Double {
        defaults.double(forKey: "shift." + source.key)
    }

    func setBeatShift(_ shift: Double, for source: GifSource) {
        defaults.set(shift, forKey: "shift." + source.key)
    }
}

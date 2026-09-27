import AppKit
import DancefloorCore

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

    var isGiphy: Bool { if case .giphy = self { true } else { false } }
}

struct LoadedGif {
    let source: GifSource
    let title: String
    let data: Data
    let animation: GIFAnimation
}

enum SourceMode: String, CaseIterable {
    case both, giphy, local

    var title: String {
        switch self {
        case .both: "GIPHY + My Folder"
        case .giphy: "GIPHY Only"
        case .local: "My Folder Only"
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
            case .noResults(let q): "GIPHY had no stickers for \"\(q)\"."
            case .unreadable: "That file isn't a readable GIF."
            }
        }
    }

    static let randomTerms = [
        "dancing", "dance", "twerk", "shrek dance", "dancing cat", "dancing dog", "dance party",
        "dancing animal", "breakdance", "dancing baby", "dancing frog", "dancing banana", "vibing",
    ]

    let folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Dancefloor", isDirectory: true)
    private let defaults = UserDefaults.standard
    private var searchCache: [String: [GiphyClient.Gif]] = [:]

    init() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let sample = Bundle.main.url(forResource: "sample-dancer", withExtension: "gif") {
                try? fm.copyItem(at: sample, to: folder.appendingPathComponent("sample-dancer.gif"))
            }
        }
    }

    var giphyKey: String? {
        get { defaults.string(forKey: "giphyAPIKey").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "giphyAPIKey"); searchCache.removeAll() }
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

    func random(excluding current: GifSource? = nil) async throws -> LoadedGif {
        let locals = localFiles().filter { GifSource.local(path: $0.path) != current }
        let canGiphy = giphyKey != nil && mode != .local
        let canLocal = !locals.isEmpty && mode != .giphy

        if canGiphy && (!canLocal || Bool.random()) {
            return try await search(Self.randomTerms.randomElement()!, deep: true)
        }
        guard canLocal, let file = locals.randomElement() else { throw Failure.nothingToPick }
        return try loadLocal(.local(path: file.path), title: file.deletingPathExtension().lastPathComponent)
    }

    /// A random sticker from a GIPHY search. `deep` also looks past the first page.
    func search(_ query: String, deep: Bool = false) async throws -> LoadedGif {
        guard let key = giphyKey else { throw Failure.nothingToPick }
        let client = GiphyClient(apiKey: key)
        let offset = deep ? [0, 0, 50, 100].randomElement()! : 0
        let cacheKey = "\(query.lowercased())#\(offset)"
        var results = searchCache[cacheKey]
        if results == nil {
            results = try await client.searchStickers(query, offset: offset)
            searchCache[cacheKey] = results
        }
        guard let pick = results?.filter({ $0.downloadURL != nil }).randomElement(),
              let url = pick.downloadURL else { throw Failure.noResults(query) }
        let data = try await client.download(url)
        guard let animation = GIFAnimation(data: data) else { throw Failure.unreadable }
        return LoadedGif(source: .giphy(id: pick.id, url: url.absoluteString),
                         title: pick.title.isEmpty ? query : pick.title, data: data, animation: animation)
    }

    /// Reload a saved dancer's GIF.
    func load(_ source: GifSource, title: String) async throws -> LoadedGif {
        switch source {
        case .local:
            return try loadLocal(source, title: title)
        case .giphy(_, let url):
            let data = try await GiphyClient(apiKey: giphyKey ?? "").download(URL(string: url)!)
            guard let animation = GIFAnimation(data: data) else { throw Failure.unreadable }
            return LoadedGif(source: source, title: title, data: data, animation: animation)
        }
    }

    func loadLocal(_ source: GifSource, title: String) throws -> LoadedGif {
        guard case .local(let path) = source,
              let data = FileManager.default.contents(atPath: path),
              let animation = GIFAnimation(data: data) else { throw Failure.unreadable }
        return LoadedGif(source: source, title: title, data: data, animation: animation)
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

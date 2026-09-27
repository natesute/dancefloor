import Foundation

struct GiphyClient {
    struct Gif: Decodable {
        struct Rendition: Decodable {
            let url: String?
            let size: String?
        }
        struct Images: Decodable {
            let original: Rendition
            let fixed_height: Rendition?
        }
        let id: String
        let title: String
        let images: Images

        /// Full quality unless it's huge, then the 200px-tall version.
        var downloadURL: URL? {
            let originalSize = Int(images.original.size ?? "") ?? 0
            let pick = originalSize > 0 && originalSize <= 5_000_000 ? images.original : (images.fixed_height ?? images.original)
            return pick.url.flatMap(URL.init(string:))
        }
    }

    enum Failure: LocalizedError {
        case badKey, rateLimited, http(Int)
        var errorDescription: String? {
            switch self {
            case .badKey: "GIPHY rejected the API key."
            case .rateLimited: "GIPHY rate limit hit. Beta keys allow about 100 searches an hour."
            case .http(let code): "GIPHY returned HTTP \(code)."
            }
        }
    }

    let apiKey: String

    /// Searches GIPHY stickers, which have transparent backgrounds.
    func searchStickers(_ query: String, offset: Int = 0, limit: Int = 50) async throws -> [Gif] {
        var components = URLComponents(string: "https://api.giphy.com/v1/stickers/search")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: "pg-13"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try Self.checkStatus(response)
        struct Page: Decodable { let data: [Gif] }
        return try JSONDecoder().decode(Page.self, from: data).data
    }

    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.checkStatus(response)
        return data
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let code = (response as? HTTPURLResponse)?.statusCode, code != 200 else { return }
        switch code {
        case 401, 403: throw Failure.badKey
        case 429: throw Failure.rateLimited
        default: throw Failure.http(code)
        }
    }
}

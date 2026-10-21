import Foundation

public struct Station: Equatable {
    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    public static func parse(_ text: String) throws -> [Station] {
        try text.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty,
                  let url = URL(string: parts[1]),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else {
                throw RadioError.message("Invalid station on line \(index + 1). Use Name|https://stream-url.")
            }
            return Station(name: parts[0], url: parts[1])
        }
    }
}

public enum RadioError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

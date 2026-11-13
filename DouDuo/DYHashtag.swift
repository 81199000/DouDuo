import Foundation

/// Caption fallback and platform-provided tag names share the same matching rules.
enum DYHashtag {
    struct Match {
        let name: String
        let range: Range<String.Index>
    }

    private static let pattern = try? NSRegularExpression(pattern: #"[#＃]([\p{L}\p{M}\p{N}_\p{So}\x{200D}\x{FE0F}]+)"#)

    static func matches(in text: String, knownNames: [String] = []) -> [Match] {
        var result: [Match] = []
        // Platform names can contain spaces/punctuation that a caption alone cannot disambiguate.
        for name in knownNames.sorted(by: { $0.count > $1.count }) where !name.isEmpty {
            for prefix in ["#", "＃"] {
                var start = text.startIndex
                while start < text.endIndex,
                      let range = text.range(of: prefix + name, range: start..<text.endIndex) {
                    if !result.contains(where: { $0.range.overlaps(range) }) {
                        result.append(Match(name: name, range: range))
                    }
                    start = range.upperBound
                }
            }
        }
        for match in pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let range = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text),
                  !result.contains(where: { $0.range.overlaps(range) }) else { continue }
            result.append(Match(name: String(text[nameRange]), range: range))
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func name(from input: String) -> String? {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("#") || name.hasPrefix("＃") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("#"), !name.contains("＃"),
              name.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) || $0.properties.generalCategory == .otherSymbol }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 0x200D }) else { return nil }
        return name
    }

    static func names(in text: String, knownNames: [String] = []) -> [String] {
        var seen = Set<String>()
        return (knownNames + matches(in: text, knownNames: knownNames).map(\.name))
            .compactMap { name(from: $0) }
            .filter { seen.insert(key($0)).inserted }
    }

    static func searchURL(for name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "douduo"
        components.host = "hashtag"
        components.queryItems = [URLQueryItem(name: "tag", value: name)]
        return components.url
    }

    static func searchName(from url: URL) -> String? {
        guard url.scheme == "douduo", url.host == "hashtag" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "tag" })?.value.flatMap { name(from: $0) }
    }
}

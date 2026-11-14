import Foundation

struct DYHashtagFilter {
    static let storageKey = "douyin_blocked_hashtags_v1"
    private(set) var tags: [String]
    private var keys: Set<String>

    init(rawValue: String = "") {
        let saved = (try? JSONDecoder().decode([String].self, from: Data(rawValue.utf8))) ?? []
        var seen = Set<String>()
        tags = saved.compactMap { DYHashtag.name(from: $0) }
            .filter { seen.insert(DYHashtag.key($0)).inserted }
        keys = seen
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(tags) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    func contains(_ tag: String) -> Bool { keys.contains(DYHashtag.key(tag)) }

    func blocks(description: String, knownNames: [String] = []) -> Bool {
        guard !keys.isEmpty else { return false }
        return DYHashtag.names(in: description, knownNames: knownNames).contains(where: contains)
    }

    enum AddResult { case added, duplicate, invalid }

    mutating func add(_ input: String) -> AddResult {
        guard let tag = DYHashtag.name(from: input) else { return .invalid }
        guard keys.insert(DYHashtag.key(tag)).inserted else { return .duplicate }
        tags.append(tag)
        return .added
    }

    mutating func remove(_ tag: String) {
        keys.remove(DYHashtag.key(tag))
        tags.removeAll { DYHashtag.key($0) == DYHashtag.key(tag) }
    }
}

extension DYAweme {
    var hashtags: [String] { DYHashtag.names(in: desc, knownNames: hashtagNames ?? []) }
}

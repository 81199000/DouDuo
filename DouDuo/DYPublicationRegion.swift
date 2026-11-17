import Foundation

/// The work's city code, not author profile/POI location or verified IP attribution.
enum DYPublicationRegion {
    private static let names: [String: String] = {
        guard let url = Bundle.main.url(forResource: "DouyinPublicationRegions", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    static func name(for code: String?, country: String? = nil) -> String? {
        name(for: code, country: country, names: names)
    }

    static func name(for code: String?, country: String?, names: [String: String]) -> String? {
        let country = country?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard ["", "CN", "HK", "MO", "TW"].contains(country),
              let code, code.utf8.count == 6, code != "000000",
              code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return names[code]
    }

    static func metadata(_ original: String?, place: String?, resolved: Bool = true) -> String? {
        let showRegion = place != nil || resolved
        let parts = [original, showRegion ? "发布地：" + (place ?? "未知") : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

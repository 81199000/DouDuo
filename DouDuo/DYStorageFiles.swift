import Foundation
import OSLog

actor DYStorageFiles {
    static let shared = DYStorageFiles()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DouDuo", category: "Storage")
    static let videoWorkDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dd-video-work", isDirectory: true)

    static let offlineDirectoryName = "dd-offline-videos"
    static let offlineWorkDirectoryName = "dd-offline-work"

    enum Category: String, CaseIterable {
        case video
        case offline
        case images
        case web
        case diagnostics
        case other
    }

    enum OtherArea: String, CaseIterable {
        case documents = "文稿"
        case appSupport = "本地应用资料"
        case caches = "其他运行缓存"
        case preferences = "偏好设置"
        case temporary = "临时文件"
        case library = "其他资料库文件"

        init(path: [String]) {
            let parts = path.prefix(2)
            if parts.starts(with: ["Documents"]) { self = .documents }
            else if parts.starts(with: ["tmp"]) { self = .temporary }
            else if Array(parts) == ["Library", "Application Support"] { self = .appSupport }
            else if Array(parts) == ["Library", "Caches"] { self = .caches }
            else if Array(parts) == ["Library", "Preferences"] { self = .preferences }
            else { self = .library }
        }
    }

    struct Usage: Equatable {
        var app: Int64 = 0
        var deviceCapacity: Int64?
        var isPartial = false
        var categories: [Category: Int64] = [:]
        var otherAreas: [OtherArea: Int64] = [:]
        var data: Int64 { categories.values.reduce(0, +) }
        var total: Int64 { app + data }
    }

    /// 按磁盘已分配字节统计。系统设置另有自己的计量方式。
    func scan(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        bundle: URL = Bundle.main.bundleURL
    ) throws -> Usage {
        var usage = Usage()
        if let capacity = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity {
            usage.deviceCapacity = Int64(capacity)
        }
        let bundleComplete = try Self.enumerateFiles(in: bundle) { _, _, bytes in usage.app += bytes }
        usage.isPartial = !bundleComplete

        // 容器根目录还可能有系统管理的子目录。只统计 App 可访问的数据范围。
        for area in ["Documents", "Library", "tmp"] {
            let directory = home.appendingPathComponent(area, isDirectory: true)
            let complete = try Self.enumerateFiles(in: directory) { file, level, bytes in
                // 枚举结果与根 URL 的绝对路径写法可能不同（如 /var 与 /private/var）。
                let relativePath = [area] + file.pathComponents.suffix(level)
                let category = Self.category(relativePath)
                usage.categories[category, default: 0] += bytes
                if category == .other { usage.otherAreas[OtherArea(path: relativePath), default: 0] += bytes }
            }
            if !complete { usage.isPartial = true }
        }
        if usage.isPartial && usage.total == 0 { throw CocoaError(.fileReadUnknown) }
        return usage
    }

    private static func enumerateFiles(in directory: URL, visit: (URL, Int, Int64) -> Void) throws -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let resourceKeys = Set(keys)
        var firstError: NSError?
        func record(_ error: Error) {
            // 活跃缓存可能在扫描过程中消失。
            if firstError == nil && !isMissing(error) { firstError = error as NSError }
        }
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            errorHandler: { _, error in
                record(error)
                return true
            }
        )
        guard let enumerator else { return false }

        for case let file as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try file.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true else { continue }
                let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize
                if let bytes {
                    visit(file, enumerator.level, Int64(bytes))
                } else {
                    record(CocoaError(.fileReadUnknown))
                }
            } catch {
                record(error)
            }
        }
        try Task.checkCancellation()
        guard let error = firstError else { return true }
        log.warning("Partial scan in \(directory.lastPathComponent, privacy: .public): \(error.domain, privacy: .public) (\(error.code))")
        return false
    }

    private static func category(_ path: [String]) -> Category {
        switch Array(path.prefix(3)) {
        case ["Documents", "ddlog.txt"]:
            return .diagnostics
        case let parts where parts.starts(with: ["tmp"]):
            guard parts.count > 1 else { return .other }
            let name = parts[1]
            if name == offlineWorkDirectoryName { return .offline }
            if name.hasPrefix("CFNetworkDownload_") { return .video }
            return name == videoWorkDirectory.lastPathComponent || isLegacyVideoWork(name) ? .video : .other
        case ["Library", "Caches", "dd-videos"]:
            return .video
        case ["Library", "Application Support", offlineDirectoryName]:
            return .offline
        case ["Library", "Caches", "ImageCache"],
             ["Library", "Caches", "dd-chat-images"],
             ["Library", "Caches", "chat-snapshots"]:
            return .images
        case let parts where parts.starts(with: ["Library", "WebKit"]):
            return .web
        case let parts where parts.starts(with: ["Library", "Caches"]) && parts.count == 3:
            let name = parts[2]
            // Foundation 与 WebKit 也会把数据放进 Caches/<bundle-id>/。
            let nestedName = path.count > 3 ? path[3] : ""
            return name == "dd-url-cache" || name == "WebKit" || name.hasPrefix("com.apple.WebKit.")
                || nestedName == "dd-url-cache" || nestedName == "WebKit" ? .web : .other
        default:
            return .other
        }
    }

    private static func isLegacyVideoWork(_ name: String) -> Bool {
        (name.hasPrefix("ddseg-") || name.hasPrefix("ddrest-"))
            && UUID(uuidString: String(name.suffix(36))) != nil
    }

    /// 视频下载被取消（划走了）时系统留下的半截下载 CFNetworkDownload_*.tmp。
    /// 只算超过 10 分钟没动的，正在下载的不碰
    private static func isStaleSystemDownload(_ file: URL) -> Bool {
        guard file.lastPathComponent.hasPrefix("CFNetworkDownload_"), file.pathExtension == "tmp" else { return false }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Date().timeIntervalSince(modified) > 600
    }

    /// 只清理视频缓存器拥有的临时目录，避开导出到相册时使用的其他暂存文件。
    static func removeVideoWork() -> Bool {
        var success = removeIfPresent(videoWorkDirectory)
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
            )
            for file in files where isLegacyVideoWork(file.lastPathComponent) || isStaleSystemDownload(file) {
                if !removeIfPresent(file) { success = false }
            }
        } catch {
            if !isMissing(error) { success = false }
        }
        return success
    }

    static func removeIfPresent(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return isMissing(error)
        }
    }

    static func resetCacheDirectory(_ directory: URL) -> Bool {
        guard removeIfPresent(directory) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(POSIXErrorCode.ENOENT.rawValue)
        }
        return nsError.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)
    }
}

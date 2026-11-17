import Foundation

/// 离线下载的数据与自动缓存分开。完整文件和元数据一起提交，断电或中断时不会留下可见的半成品。
enum DYOfflineVideoStore {
    private static let directory = URL.applicationSupportDirectory.appendingPathComponent(DYStorageFiles.offlineDirectoryName, isDirectory: true)
    static let stagingDirectory = URL.temporaryDirectory.appendingPathComponent(DYStorageFiles.offlineWorkDirectoryName, isDirectory: true)

    private struct Record: Codable {
        let video: DYAweme
        let savedAt: Date
        var lastPlayedAt: Date? = nil
        var firstCompletedAt: Date? = nil
    }

    struct Library {
        let videos: [DYAweme]
        let expiresAt: Date?
        var removedExpiredVideos = false

        var duration: TimeInterval {
            videos.reduce(0) { total, video in
                let duration = video.duration
                return duration.isFinite && duration > 0 ? total + duration : total
            }
        }
    }

    struct PlaybackCheckpoint: Codable, Equatable {
        let id: String
        let seconds: Double
    }

    private static var checkpointURL: URL { directory.appendingPathComponent("playback-position.json") }

    static func loadCheckpoint() -> PlaybackCheckpoint? {
        guard let data = try? Data(contentsOf: checkpointURL),
              let checkpoint = try? JSONDecoder().decode(PlaybackCheckpoint.self, from: data),
              checkpoint.seconds.isFinite, checkpoint.seconds >= 0, localURL(checkpoint.id) != nil else { return nil }
        return checkpoint
    }

    @discardableResult
    static func saveCheckpoint(_ checkpoint: PlaybackCheckpoint) -> Bool {
        // Keep the checkpoint inside the offline library so retention and manual
        // deletion remove it, and a late player callback cannot recreate the library.
        guard checkpoint.seconds.isFinite, checkpoint.seconds >= 0, localURL(checkpoint.id) != nil,
              let data = try? JSONEncoder().encode(checkpoint) else { return false }
        do {
            try data.write(to: checkpointURL, options: .atomic)
            return true
        } catch { return false }
    }

    private static let day: TimeInterval = 24 * 60 * 60

    private static func folder(_ id: String) -> URL? {
        guard !id.isEmpty, id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true)
    }

    static func localURL(_ id: String) -> URL? {
        guard let file = folder(id)?.appendingPathComponent("video.mp4") else { return nil }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static func records() -> [Record] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Record? in
            guard fm.fileExists(atPath: folder.appendingPathComponent("video.mp4").path),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("video.json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
            return record
        }
        .sorted { $0.savedAt < $1.savedAt }
    }

    private static func expiration(of records: [Record]) -> Date? {
        let completions = records.compactMap(\.firstCompletedAt)
        if completions.count == records.count, let lastCompletion = completions.max() {
            return lastCompletion.addingTimeInterval(3 * day)
        }
        return records.map { max($0.savedAt, $0.lastPlayedAt ?? $0.savedAt) }.max()?
            .addingTimeInterval(7 * day)
    }

    static func snapshot(now: Date = Date()) -> [DYAweme] {
        let records = records()
        if let expiresAt = expiration(of: records), expiresAt <= now { return [] }
        return records.map(\.video)
    }

    static func refreshRetention(now: Date = Date()) -> Library {
        let records = records()
        let expiresAt = expiration(of: records)
        if let expiresAt, expiresAt <= now {
            return removeExpiredLibrary()
        }
        return Library(videos: records.map(\.video), expiresAt: expiresAt)
    }

    private static func removeExpiredLibrary() -> Library {
        Library(videos: [], expiresAt: nil, removedExpiredVideos: removeAll())
    }

    static func recordPlayback(id: String, completed: Bool, now: Date = Date()) -> Library? {
        guard let metadata = folder(id)?.appendingPathComponent("video.json"), localURL(id) != nil else { return nil }
        var records = records()
        guard let index = records.firstIndex(where: { $0.video.id == id }) else { return nil }
        if let expiresAt = expiration(of: records), expiresAt <= now { return removeExpiredLibrary() }
        var record = records[index]
        record.lastPlayedAt = max(record.lastPlayedAt ?? record.savedAt, now)
        if completed && record.firstCompletedAt == nil {
            record.firstCompletedAt = now
        }
        do {
            try JSONEncoder().encode(record).write(to: metadata, options: .atomic)
        } catch {
            return nil
        }
        records[index] = record
        return Library(videos: records.map(\.video), expiresAt: expiration(of: records))
    }

    static func save(_ video: DYAweme, file: URL, copying: Bool, staging: URL) throws {
        guard let destination = folder(video.id) else { throw URLError(.badURL) }
        let fm = FileManager.default
        var root = directory
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
        }
        let ready = staging.appendingPathComponent("Ready", isDirectory: true)
        try fm.createDirectory(at: ready, withIntermediateDirectories: true)
        let mp4 = ready.appendingPathComponent("video.mp4")
        if copying {
            try fm.copyItem(at: file, to: mp4)
        } else {
            try fm.moveItem(at: file, to: mp4)
        }
        let metadata = try JSONEncoder().encode(Record(video: video, savedAt: Date()))
        try metadata.write(to: ready.appendingPathComponent("video.json"))
        try Task.checkCancellation()
        try fm.moveItem(at: ready, to: destination)
    }

    static func removeAll() -> Bool {
        DYStorageFiles.removeIfPresent(directory)
    }

    static func availableBytes() -> Int? {
        try? URL.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
    }
}

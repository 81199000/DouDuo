#!/usr/bin/env python3
"""Exercise offline retention against existing on-disk video records."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
import Foundation

@MainActor enum DYLiveModel {
    static func log(_ message: String) {}
}

struct DYAweme: Codable {
    let id: String
    let duration: Double
}

@main struct OfflineRetentionTest {
    struct LegacyRecord: Encodable {
        let video: DYAweme
        let savedAt: Date
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSinceReferenceDate: 500_000_000)
        func date(_ days: Double) -> Date { start.addingTimeInterval(days * day) }
        func addLegacy(_ id: String, duration: Double, savedAt: Date) throws {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0]).write(to: folder.appendingPathComponent("video.mp4"))
            let record = LegacyRecord(video: DYAweme(id: id, duration: duration), savedAt: savedAt)
            try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("video.json"))
        }

        precondition(DYOfflineVideoStore.refreshRetention(now: date(0)).expiresAt == nil)
        try addLegacy("first", duration: 30, savedAt: date(0))
        try addLegacy("second", duration: 45, savedAt: date(1))
        let oldLibrary = DYOfflineVideoStore.refreshRetention(now: date(1))
        precondition(oldLibrary.videos.map(\.id) == ["first", "second"])
        precondition(oldLibrary.duration == 75)
        precondition(oldLibrary.expiresAt == date(8))

        let startedFirst = DYOfflineVideoStore.recordPlayback(id: "first", completed: false, now: date(5))
        precondition(startedFirst?.expiresAt == date(12))
        let watchedFirst = DYOfflineVideoStore.recordPlayback(id: "first", completed: true, now: date(5.1))
        precondition(watchedFirst?.expiresAt == date(12.1))
        let watchedAll = DYOfflineVideoStore.recordPlayback(id: "second", completed: true, now: date(6))
        precondition(watchedAll?.expiresAt == date(9))
        let rewatched = DYOfflineVideoStore.recordPlayback(id: "second", completed: true, now: date(7))
        precondition(rewatched?.expiresAt == date(9), "Replay must not restart the three-day clock")
        precondition(DYOfflineVideoStore.refreshRetention(now: date(8.9)).videos.count == 2)

        try addLegacy("third", duration: 20, savedAt: date(8.9))
        let refilled = DYOfflineVideoStore.refreshRetention(now: date(9))
        precondition(refilled.expiresAt == date(15.9), "New unwatched downloads restore the inactivity deadline")
        precondition(refilled.duration == 95)
        precondition(DYOfflineVideoStore.snapshot(now: date(15.8)).count == 3)
        precondition(DYOfflineVideoStore.snapshot(now: date(15.9)).isEmpty)
        precondition(DYOfflineVideoStore.refreshRetention(now: date(15.9)).removedExpiredVideos)
        precondition(!FileManager.default.fileExists(atPath: root.path))

        try addLegacy("unwatched", duration: 90, savedAt: date(20))
        // Playback reporting may arrive on a delayed callback. An expired library cannot be revived.
        let latePlayback = DYOfflineVideoStore.recordPlayback(id: "unwatched", completed: false, now: date(27))
        precondition(latePlayback?.removedExpiredVideos == true)
        precondition(DYOfflineVideoStore.localURL("unwatched") == nil)
    }
}
'''


class OfflineRetentionTests(unittest.TestCase):
    def test_expiration_and_legacy_metadata(self):
        with tempfile.TemporaryDirectory(prefix="douduo-offline-retention-") as directory:
            root = Path(directory)
            store = root / "DYOfflineVideoStore.swift"
            source = (ROOT / "DouDuo" / store.name).read_text()
            production_root = "URL.applicationSupportDirectory.appendingPathComponent(DYStorageFiles.offlineDirectoryName, isDirectory: true)"
            self.assertEqual(source.count(production_root), 1)
            store.write_text(source.replace(
                production_root, "URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)"
            ))
            harness = root / "OfflineRetentionTest.swift"
            harness.write_text(HARNESS)
            executable = root / "test-offline-retention"
            subprocess.run(
                ["swiftc", "-module-cache-path", str(root / "modules"), str(store),
                 str(ROOT / "DouDuo" / "DYStorageFiles.swift"), str(harness), "-o", str(executable)],
                check=True, timeout=120,
            )
            subprocess.run([executable, root / "offline"], check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()

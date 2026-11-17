#!/usr/bin/env python3
"""Regression test for storage scans on a container with unreadable directories."""

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

@main struct StorageScanTest {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = root.appendingPathComponent("data", isDirectory: true)
        let bundle = root.appendingPathComponent("DouDuo.app", isDirectory: true)
        let scanner = DYStorageFiles()
        let usage = try await scanner.scan(home: home, bundle: bundle)
        precondition(usage.app >= 32_768, "App bundle must stay visible")
        precondition(usage.categories[.video, default: 0] >= 65_536, "Video cache must stay visible")
        precondition(usage.categories[.diagnostics, default: 0] >= 8_192, "Documents must stay visible")
        precondition(usage.categories[.images, default: 0] >= 16_384, "Readable Library siblings must stay visible")
        precondition(usage.categories[.offline, default: 0] >= 16_384, "Manual downloads must be counted separately")
        precondition(usage.categories[.web, default: 0] >= 24_576, "App-scoped URL cache must count as web data")
        precondition(usage.categories[.other, default: 0] == 4096, "Do not include system-managed data")
        precondition(usage.otherAreas[.caches, default: 0] == 4096, "Keep unrelated caches in other data")
        precondition(usage.isPartial == (CommandLine.arguments[2] == "partial"), "Incorrect completeness status")
        print("PASS storage scan: \(usage.isPartial ? "partial" : "complete")")
    }
}
'''


class StorageScanTests(unittest.TestCase):
    def test_permission_error_preserves_browsable_usage(self):
        with tempfile.TemporaryDirectory(prefix="douduo-storage-scan-") as directory:
            root = Path(directory)
            swift = root / "StorageScanTest.swift"
            swift.write_text(HARNESS)
            executable = root / "test-storage-scan"
            subprocess.run(
                ["swiftc", "-module-cache-path", str(root / "modules"),
                 str(ROOT / "DouDuo" / "DYStorageFiles.swift"), str(swift), "-o", str(executable)],
                check=True, timeout=120,
            )
            for relative, size in [
                ("DouDuo.app/binary", 32_768),
                ("data/Library/Caches/dd-videos/movie", 65_536),
                ("data/Library/Caches/ImageCache/image", 16_384),
                ("data/Documents/ddlog.txt", 8_192),
                ("data/Library/Application Support/dd-offline-videos/movie/video.mp4", 16_384),
                ("data/Library/Caches/me.rrmm.douduo/dd-url-cache/entry", 24_576),
                ("data/Library/Caches/me.rrmm.douduo/com.apple.metal/file", 4096),
                ("data/SystemData/private", 131_072),
                ("data/Library/WebKit/inaccessible/hidden", 65_536),
            ]:
                file = root / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b"x" * size)

            system_data = root / "data/SystemData"
            unreadable = root / "data/Library/WebKit/inaccessible"
            system_data.chmod(0)
            try:
                subprocess.run([executable, root, "complete"], check=True, timeout=15)
                unreadable.chmod(0)
                subprocess.run([executable, root, "partial"], check=True, timeout=15)
            finally:
                system_data.chmod(0o700)
                unreadable.chmod(0o700)


if __name__ == "__main__":
    unittest.main()

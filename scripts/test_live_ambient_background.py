#!/usr/bin/env python3
"""编译直播环境光的纯计算，并检查视图不会在 body 里重做模糊。

Run: python3 scripts/test_live_ambient_background.py -v
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo/DouyinLiveAmbientBackground.swift"
LAYOUT = ROOT / "DouDuo/DouyinLiveAdaptiveLayout.swift"
ROOM = ROOT / "DouDuo/DouyinLiveRoom.swift"

HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let vertical = DYLiveAmbientTreatment.fade(for: .vertical)
check(vertical.start == .minY && vertical.end == .maxY, "layout A fades downward from the hinge")
let horizontal = DYLiveAmbientTreatment.fade(for: .horizontal)
check(horizontal.start == .minX && horizontal.end == .maxX, "layout B fades rightward from the hinge")
check(vertical != horizontal, "layout A and layout B use different fade directions")
check(DYLiveAmbientTreatment.axis(for: .layoutA) == .vertical, "layout A maps to the vertical ambient")
check(DYLiveAmbientTreatment.axis(for: .layoutB) == .horizontal, "layout B maps to the horizontal ambient")
check(DYLiveAmbientTreatment.axis(for: .existing) == nil, "the full-screen layout does not request an ambient pane")

let near = DYLiveAmbientTreatment.artworkOpacity(at: 0)
let far = DYLiveAmbientTreatment.artworkOpacity(at: 1)
check(near > far + 0.4, "the hinge keeps more cover color than the outer edge")
check(DYLiveAmbientTreatment.opacity(at: 1, stops: DYLiveAmbientTreatment.veilStops) >= DYLiveAmbientTreatment.opacity(at: 0, stops: DYLiveAmbientTreatment.veilStops), "the outer edge is at least as dark as the hinge")
check(DYLiveAmbientTreatment.plateOpacity >= 0.5 && DYLiveAmbientTreatment.plateOpacity <= 0.62, "the plate stays lighter than a flat 76 percent black")
check(DYLiveAmbientTreatment.sourceMaxPixel <= 96, "the blur source stays thumbnail sized")
check(DYLiveAmbientTreatment.transitionDuration > 0 && DYLiveAmbientTreatment.transitionDuration < 1, "artwork changes use one short fade")

let fallback = DYLiveAmbientTreatment.fallback
check(fallback.red < 0.12 && fallback.green < 0.12 && fallback.blue < 0.12, "missing artwork falls back to a dark field")
check(fallback.red > 0.02 && fallback.green > 0.02 && fallback.blue > 0.02, "the fallback is neutral dark rather than a pure hole")

let samples: [(String, DYLiveAmbientRGB?)] = [
    ("missing", nil),
    ("white", DYLiveAmbientRGB(red: 1, green: 1, blue: 1)),
    ("yellow", DYLiveAmbientRGB(red: 1, green: 1, blue: 0)),
    ("red", DYLiveAmbientRGB(red: 1, green: 0, blue: 0)),
    ("cyan", DYLiveAmbientRGB(red: 0, green: 1, blue: 1)),
    ("black", DYLiveAmbientRGB(red: 0, green: 0, blue: 0)),
    ("dark", DYLiveAmbientRGB(red: 0.04, green: 0.05, blue: 0.08)),
]
for (name, artwork) in samples {
    for location: CGFloat in [0, 0.5, 1] {
        let contrast = DYLiveAmbientTreatment.whiteTextContrast(artwork: artwork, location: location)
        check(contrast >= DYLiveAmbientTreatment.minimumTextContrast, "\(name) at \(location) keeps white text readable")
    }
}
let missing = DYLiveAmbientTreatment.backdrop(artwork: nil, location: 0.5)
check(missing.red < 0.08 && missing.green < 0.08 && missing.blue < 0.08, "a missing cover stays on the dark plate")
let glow = DYLiveAmbientRGB(red: 0.1, green: 0.35, blue: 0.85)
let hingeGlow = DYLiveAmbientTreatment.backdrop(artwork: glow, location: 0)
let outerGlow = DYLiveAmbientTreatment.backdrop(artwork: glow, location: 1)
check(hingeGlow.blue > outerGlow.blue + 0.15, "colored artwork stays visible at the video edge and fades outward")
check(hingeGlow.blue > hingeGlow.red, "the hinge glow follows the artwork instead of turning gray")

var stripe = [UInt8](repeating: 0, count: 5 * 4)
stripe[8] = 255
stripe[9] = 255
stripe[10] = 255
stripe[11] = 255
let sharp = DYLiveAmbientBitmap(width: 5, height: 1, rgba: stripe)
let blurred = DYLiveAmbientBlur.boxBlur(sharp, radius: 1)
check(blurred.rgba[0] == 0 && blurred.rgba[4] == 85 && blurred.rgba[8] == 85 && blurred.rgba[12] == 85 && blurred.rgba[16] == 0, "a one-pixel spike spreads to its neighbors")
let soft = DYLiveAmbientBlur.soften(sharp)
check(soft.width == 5 && soft.height == 1, "soften keeps the bitmap size")
check(Int(soft.rgba[8]) < 255, "soften removes a hard edge")

let memo = DYLiveAmbientMemo<Int>(limit: 2)
var builds = 0
let first = memo.resolve(key: "room-a") { builds += 1; return 7 }
let second = memo.resolve(key: "room-a") { builds += 1; return 9 }
check(first == 7 && second == 7 && builds == 1 && memo.renders == 1, "the same artwork is blurred once")
check(memo.peek("room-a") == 7 && memo.renders == 1, "a cache hit does not render")
_ = memo.resolve(key: "room-b") { builds += 1; return 1 }
_ = memo.resolve(key: "room-c") { builds += 1; return 2 }
check(memo.peek("room-a") == nil, "the oldest room leaves the small cache")
_ = memo.resolve(key: "room-a") { builds += 1; return 7 }
check(memo.renders == 4 && builds == 4, "an evicted room can render again, and only then")

let roomA = DYLiveAmbientIdentity.token(isolationID: "account-a", artwork: "cover:room-a")
let roomB = DYLiveAmbientIdentity.token(isolationID: "account-a", artwork: "cover:room-b")
let accountB = DYLiveAmbientIdentity.token(isolationID: "account-b", artwork: "cover:room-a")
let noArtwork = DYLiveAmbientIdentity.token(isolationID: "account-a", artwork: "fallback")
check(roomA != roomB, "a room change gets a new artwork identity")
check(roomA != accountB, "an account change gets a new identity even for the same cover")
check(DYLiveAmbientIdentity.isFallback(noArtwork), "a room without artwork is the fallback identity")
check(!DYLiveAmbientIdentity.isFallback(roomA), "a cover URL is not treated as a missing cover")
check(DYLiveAmbientIdentity.shouldApply(requested: roomA, current: roomA, cancelled: false), "the current room accepts its own image")
check(!DYLiveAmbientIdentity.shouldApply(requested: roomA, current: roomB, cancelled: false), "a finished load does not paint the next room")
check(!DYLiveAmbientIdentity.shouldApply(requested: roomA, current: accountB, cancelled: false), "the previous account does not paint the same cover onto the new account")
check(!DYLiveAmbientIdentity.shouldApply(requested: roomA, current: roomA, cancelled: true), "a cancelled load does not paint")

if failures.isEmpty {
    print("DYLiveAmbient passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


def section(text: str, start: str, end: str) -> str:
    if start not in text or end not in text:
        raise AssertionError(f"missing marker {start}")
    return text[text.index(start) + len(start):text.index(end)]


class LiveAmbientBackgroundTests(unittest.TestCase):
    def test_treatment_and_blur_cache(self):
        source = SOURCE.read_text()
        treatment = section(source, "// MARK: - ambient-treatment\n", "// MARK: - ambient-treatment-end\n")
        swift = "import CoreGraphics\n" + LAYOUT.read_text() + "\n" + treatment + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-live-ambient-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(
                ["swift", "-module-cache-path", str(Path(tmp) / "cache"), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYLiveAmbient passed", completed.stdout)

    def test_view_does_not_reprocess_in_body(self):
        source = SOURCE.read_text()
        body = section(source, "// MARK: - ambient-body\n", "// MARK: - ambient-body-end\n")
        refresh = section(source, "// MARK: - ambient-refresh\n", "// MARK: - ambient-refresh-end\n")
        for banned in ("soften", "boxBlur", "UIGraphicsImageRenderer", "loadThumb", "scaled(from"):
            self.assertNotIn(banned, body)
        self.assertIn("DYLiveAmbientTreatment.fade", body)
        self.assertIn("DYLiveAmbientTreatment.plateOpacity", body)
        self.assertIn("transitionDuration", body)
        self.assertIn("displayedKey == sourceToken", body)
        self.assertEqual(refresh.count("loadThumb("), 1)
        self.assertNotIn("ImageCache.shared.load(", refresh)
        self.assertIn("shouldApply", refresh)
        self.assertIn("soften", refresh)
        self.assertIn("peek", refresh)
        self.assertNotIn("URLSession", source)
        self.assertNotIn("VLC", source)
        self.assertNotIn("DYLiveFeed", source)
        self.assertNotIn("DouyinLiveRoom", source)
        self.assertNotIn("print(", source)
        self.assertNotIn("repeatForever", source)
        self.assertNotIn("TimelineView", source)
        room = ROOM.read_text()
        self.assertEqual(room.count("DouyinLiveAmbientBackground("), 1)
        self.assertIn('isolationID: "\\(bridge.followSession):\\(room.id)"', room)
        self.assertNotIn("isolationID: room.cover", room)
        self.assertNotIn("isolationID: room.avatar", room)


if __name__ == "__main__":
    unittest.main()

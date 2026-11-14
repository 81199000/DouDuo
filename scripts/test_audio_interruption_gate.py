#!/usr/bin/env python3
"""Compile the production non-1x interruption gate. No audio session or device."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
@main struct Regression {
    static func main() {
        var gate = DDAudioInterruptionGate()
        expect(gate.allowsAutomaticStart, "1x-equivalent clear state allows start")
        gate.began()
        expect(!gate.allowsAutomaticStart, "began blocks syncTick")
        gate.began()
        expect(gate.phase == .active, "repeated began stays active")
        gate.explicitPlay()
        expect(gate.phase == .active, "explicit play during interruption does not unlock")
        gate.ended(shouldResume: true)
        expect(gate.allowsAutomaticStart, "ended with shouldResume allows the current owner")
        gate.ended(shouldResume: false)
        expect(gate.allowsAutomaticStart, "duplicate ended is ignored")
        gate.began()
        gate.ended(shouldResume: false)
        expect(!gate.allowsAutomaticStart, "ended without resume stays latched")
        gate.explicitPlay()
        expect(gate.allowsAutomaticStart, "explicit play after the latch clears it")
        gate.began()
        gate.ended(shouldResume: true)
        gate.began()
        expect(!gate.allowsAutomaticStart, "a later interruption blocks again")
        print("PASS audio interruption gate")
    }
}
'''


def gate_source():
    text = (ROOT / "DouDuo/SeamlessAudioPlayer.swift").read_text()
    start = text.index("// BEGIN DDAudioInterruptionGate\n")
    end = text.index("// END DDAudioInterruptionGate\n")
    return text[start:end]


class AudioInterruptionGateTests(unittest.TestCase):
    def test_gate_transitions(self):
        source = "import Foundation\n" + gate_source() + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="douduo-audio-int-") as scratch:
            swift = Path(scratch) / "gate.swift"
            swift.write_text(source)
            binary = Path(scratch) / "gate"
            compiled = subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], text=True, capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            ran = subprocess.run([str(binary)], text=True, capture_output=True)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertIn("PASS audio interruption gate", ran.stdout)

    def test_sync_tick_consults_gate(self):
        text = (ROOT / "DouDuo/SeamlessAudioPlayer.swift").read_text()
        tick = text.split("private func syncTick()", 1)[1].split("private func stopEngineOutput()", 1)[0]
        owner = tick.index("activeOwner == ownerID")
        gate = tick.index("allowsAutomaticStart")
        play = tick.index("playerNode.play()")
        self.assertLess(owner, gate)
        self.assertLess(gate, play)


if __name__ == "__main__":
    unittest.main()

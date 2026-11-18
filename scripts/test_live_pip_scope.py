#!/usr/bin/env python3
"""Exercise Featured detail requests and account resets without WebKit, network, or a device."""
import subprocess
import tempfile
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "DouDuo"


def definition(source, signature):
    """Return a complete top-level type or a method at its original indentation."""
    start = source.index(signature)
    indent = signature[:len(signature) - len(signature.lstrip())]
    end = source.index("\n" + indent + "}\n", start) + len(indent) + 2
    return source[start:end]


class LivePiPScopeTests(unittest.TestCase):
    def test_both_feed_hosts_invalidate_on_expiration_and_login(self):
        feed = (APP / "DouyinFeedView.swift").read_text()
        for host in ["DYUpstreamFeedScreen", "DYClassicFeedScreen"]:
            with self.subTest(host=host):
                body = definition(feed, "struct " + host + ":")
                self.assertRegex(body, r"onReceive\(NotificationCenter\.default\.publisher\(for: \.dySessionLost\)\)\s*\{\s*_ in\s*live\.sessionDidExpire\(bridge, reload: tab == \.live\)")
                reload = definition(body, "    private func reloadAfterLogin()")
                self.assertLess(reload.index("live.invalidateFollowLive()"), reload.index("live.reset()"))

    def test_expiration_resets_before_reloading(self):
        live = (APP / "DouyinLiveRoom.swift").read_text()
        method = definition(live, "    func sessionDidExpire(")
        steps = ["bridge.invalidateFollowSession()", "invalidateFollowLive()", "reset()", "if reload"]
        self.assertEqual([method.index(step) for step in steps], sorted(method.index(step) for step in steps))
        self.assertRegex(method[method.index("if reload"):], r"\b(load|reload)\(")
        self.assertLess(method.index("reset()"), method.index("Task {"))
        invalidate = definition(live, "    func invalidateFollowLive()")
        self.assertIn("cancelFeaturedPrefetch()", invalidate)
        self.assertIn("verifiedFeaturedPiPDetail = nil", invalidate)

    def test_candidate_eligibility_and_obsolete_responses(self):
        live = (APP / "DouyinLiveRoom.swift").read_text()
        feed = (APP / "DouyinFeedView.swift").read_text()
        bridge = "\n".join([
            definition(feed, "    func invalidateFollowSession()"),
            definition(feed, "    func resolveLivePlaybackRoom("),
            definition(feed, "    func prefetchFeaturedPiP("),
        ])
        types = "\n".join(definition(live, "struct " + name) for name in
                          ["DYFeaturedPiPInput:", "DYFeaturedPiPMetadata {"])
        eligibility = "\n".join(definition(live, "    var " + name + ":") for name in
                                ["pendingFeaturedPiPInput", "featuredPrefetchInput"])
        program = (SWIFT.replace("/* room types */", types)
                   .replace("/* bridge methods */", bridge)
                   .replace("/* eligibility */", eligibility))
        with tempfile.TemporaryDirectory(prefix="live-pip-scope-") as temporary:
            root = Path(temporary)
            main, binary = root / "Scope.swift", root / "scope"
            main.write_text(program)
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                            str(root / "cache"), str(APP / "FollowLiveLogic.swift"),
                            str(APP / "DYLivePiPPolicy.swift"),
                            str(main), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=15)


SWIFT = r"""
import Foundation

struct DYLiveRoom {
    let id: String
    let webRid: String
    let url: URL
    func hlsURL(for quality: String) -> URL? { quality == "HD1" ? url : nil }
}
/* room types */

@MainActor final class Bridge {
    var followSessionCache = DYFollowSessionCache(ttl: 15)
    var followSession = 0
    var ready = true
    var featuredPrefetchBusy = false

    enum Kind { case rooms }
    struct Reply {
        let kind = Kind.rooms
        let items: [DYLiveRoom]
    }
    var pending: CheckedContinuation<Reply, Never>?
    var requestCount = 0
    func performFollowRoom(_ webRid: String) async -> Reply {
        precondition(webRid == "web")
        requestCount += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func waitUntilIssued() async {
        while pending == nil { await Task.yield() }
    }

    func finish(_ room: DYLiveRoom) {
        let operation = pending
        pending = nil
        operation!.resume(returning: Reply(items: [room]))
    }

    /* bridge methods */
}

private struct Eligibility {
    struct Session {
        var phase: DYLivePiPPhase = .preparing
        var preparing: Bool { phase == .preparing || phase == .warming }
    }
    struct Source { let isFLV: Bool; let url: URL }
    var currentListedPiPInput: DYFeaturedPiPInput?
    var sources: [Source]
    var pipSession = Session()
    var pipRetryPending = false
    var pipAttempts = DYLivePiPAttempts()
    /* eligibility */
}

@main @MainActor enum Scenarios {
    static func main() async {
        let detail = URL(string: "https://fixture.invalid/detail")!
        let room = DYLiveRoom(id: "room", webRid: "web", url: detail)
        let input = DYFeaturedPiPInput(generation: UUID(), roomID: room.id, webRid: room.webRid,
            quality: "HD1", listedHLS: URL(string: "https://fixture.invalid/listed")!)
        var state = Eligibility(currentListedPiPInput: input, sources: [.init(isFLV: false, url: input.listedHLS)])
        precondition(state.featuredPrefetchInput == input && state.pendingFeaturedPiPInput == nil)
        state.pipSession.phase = .prepared
        precondition(state.featuredPrefetchInput == nil && state.pendingFeaturedPiPInput == nil)
        state.pipSession.phase = .idle
        precondition(state.pipAttempts.record(.notLoaded) != nil)
        state.pipRetryPending = true
        precondition(state.featuredPrefetchInput == input && state.pendingFeaturedPiPInput == nil)
        state.pipRetryPending = false
        state.pipSession.phase = .preparing
        precondition(state.pendingFeaturedPiPInput == nil)
        state.pipSession.phase = .idle
        precondition(state.pipAttempts.record(.notLoaded) == nil && state.pendingFeaturedPiPInput == input)
        state.sources = [.init(isFLV: true, url: input.listedHLS)]
        precondition(state.featuredPrefetchInput == nil && state.pendingFeaturedPiPInput == input)
        state.currentListedPiPInput = nil
        precondition(state.featuredPrefetchInput == nil && state.pendingFeaturedPiPInput == nil)
        for scenario in ["accepted", "replaced account", "cancelled", "wrong room"] {
            let bridge = Bridge()
            let first = bridge.prefetchFeaturedPiP(input)!
            await bridge.waitUntilIssued()
            precondition(bridge.prefetchFeaturedPiP(input) == nil)
            if scenario == "replaced account" { bridge.invalidateFollowSession() }
            if scenario == "cancelled" { first.cancel() }
            precondition(bridge.prefetchFeaturedPiP(input) == nil)
            bridge.finish(scenario == "wrong room" ? DYLiveRoom(id: "other", webRid: "web", url: detail) : room)
            let result = await first.value
            precondition(result?.url == (scenario == "accepted" ? detail : nil), scenario)
            precondition(bridge.requestCount == 1)
            // Returning to the same room may issue a request in the new generation.
            let next = bridge.prefetchFeaturedPiP(input)!
            await bridge.waitUntilIssued()
            bridge.finish(room)
            let current = await next.value
            precondition(current?.url == detail && bridge.requestCount == 2)
        }
    }
}
"""


if __name__ == "__main__":
    unittest.main()

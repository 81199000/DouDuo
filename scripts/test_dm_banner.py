#!/usr/bin/env python3
"""Compile the production banner policy. The card is not a verified incoming message."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
banner = (root / "DouDuo/DYDMBanner.swift").read_text()
scheme = (root / "DouDuo.xcodeproj/xcshareddata/xcschemes/DouDuo.xcscheme").read_text()
probe = (root / "DouDuo/DYDMProbe.swift").read_text()
start = banner.index("// BEGIN DYDMBannerPolicy\n")
end = banner.index("// END DYDMBannerPolicy\n", start)
policy = banner[start:end].replace("// BEGIN DYDMBannerPolicy\n", "").replace("// END DYDMBannerPolicy\n", "")
assert "static let notificationsOn = true" in banner and "static let showsDetail = true" in banner, "私信通知与会话名称固定开"
assert "DOUDUO_DM_SENDER" not in banner and "DOUDUO_DM_BANNER" not in banner
assert "DOUDUO_DM_SHAPE" not in banner
shape_at = probe.index("DOUDUO_DM_SHAPE")
assert "#if DEBUG" in probe[max(0, shape_at - 240):shape_at]
assert "noteIncoming" in probe
assert probe.index("DDDM event class=") < probe.index("noteIncoming")
assert probe.split("case .diagnostic")[1].split("case .event")[0].count("noteIncoming") == 0
logs = [line.lower() for line in banner.splitlines() if "dylivemodel.log" in line.lower()]
for secret in ("cookie", "sessionid", "https://", "avatarurl", "facename"):
    assert all(secret not in line for line in logs)

program = "import Foundation\n" + policy + r'''
func input(
    probe: Bool = true, banner: Bool = true, release: Bool = false, incoming: Int = 1,
    baseline: Bool = false, diagnostic: Bool = false, messages: Bool = false, active: Bool = true,
    session: Bool = true, eventGen: Int = 3, currentGen: Int = 3,     eventEpoch: Int = 2,
    currentEpoch: Int = 2, visible: Bool = false, sender: Bool = false, alias: Bool = false
) -> DYDMBannerPolicy.Input {
    DYDMBannerPolicy.Input(
        probeEnabled: probe, bannerEnabled: banner, releaseBuild: release, incoming: incoming,
        baseline: baseline, diagnosticOnly: diagnostic, messagesVisible: messages, appActive: active,
        hasSession: session, eventGeneration: eventGen, currentGeneration: currentGen,
        eventEpoch: eventEpoch, currentEpoch: currentEpoch, bannerVisible: visible,
        senderEnabled: sender, aliasOnly: alias)
}
let off = DYDMBannerPolicy.decide(input(banner: false))
precondition(off == .ignore, "banner switch defaults to off")
precondition(DYDMBannerPolicy.decide(input(probe: false)) == .ignore, "probe alone is not implied")
precondition(DYDMBannerPolicy.decide(input(release: true)) == .present, "a release build still follows the user switch")
precondition(DYDMBannerPolicy.decide(input()) == .present, "both switches present one banner")
precondition(DYDMBannerPolicy.decide(input(incoming: 0)) == .ignore, "outgoing and other activity stay quiet")
precondition(DYDMBannerPolicy.decide(input(baseline: true)) == .ignore)
precondition(DYDMBannerPolicy.decide(input(diagnostic: true)) == .ignore)
precondition(DYDMBannerPolicy.decide(input(visible: true)) == .coalesce, "a visible banner refreshes in place instead of stacking")
precondition(DYDMBannerPolicy.decide(input(visible: true)) != .ignore, "a refresh still counts the event")
precondition(DYDMBannerPolicy.decide(input(messages: true)) == .suppress("messages"))
precondition(DYDMBannerPolicy.decide(input(active: false)) == .suppress("inactive"))
precondition(DYDMBannerPolicy.decide(input(session: false)) == .suppress("session"))
precondition(DYDMBannerPolicy.decide(input(eventGen: 2)) == .suppress("stale"))
precondition(DYDMBannerPolicy.decide(input(eventEpoch: 1)) == .suppress("stale"))
precondition(DYDMBannerPolicy.animates(reduceMotion: true) == false)
precondition(DYDMBannerPolicy.animates(reduceMotion: false) == true)
precondition(DYDMBannerPolicy.decide(input(alias: true)) == .present, "sender switch off keeps the generic banner")
precondition(DYDMBannerPolicy.decide(input(sender: true, alias: true)) == .suppress("alias"))
precondition(DYDMBannerPolicy.decide(input(sender: true)) == .present)
precondition(DYDMBannerPolicy.copy(kind: 1, name: "甲")?.message == "你有新的私信活动")
precondition(DYDMBannerPolicy.copy(kind: 2, name: "小组")?.message == "群聊有新的私信活动")
precondition(DYDMBannerPolicy.copy(kind: 1, name: " ") == nil)
precondition(DYDMBannerPolicy.copy(kind: 3, name: "甲") == nil)
precondition(DYDMBannerPolicy.avatarURL("http://p3.douyinpic.com/a") == nil)
precondition(DYDMBannerPolicy.avatarURL("https://evil.example/a") == nil)
precondition(DYDMBannerPolicy.avatarURL("https://p3.douyinpic.com/a") != nil)
var banner = DYDMBannerPresentation()
let first = DYDMBannerPresentation.Update(reliable: true, title: "甲", message: "你有新的私信活动", senderEnabled: true)
let second = DYDMBannerPresentation.Update(reliable: true, title: "乙", message: "你有新的私信活动", senderEnabled: true)
let ambiguous = DYDMBannerPresentation.Update(reliable: false, title: "丙", message: "你有新的私信活动", senderEnabled: true)
let generic = DYDMBannerPresentation.Update(reliable: false, title: "丁", message: "你有新的私信活动", senderEnabled: false)
let present = DYDMBannerPolicy.decide(input())
let refresh = DYDMBannerPolicy.decide(input(visible: true))
precondition(banner.receive(present, first) == 1)
precondition(banner.visible && banner.events == 1 && banner.title == "甲" && banner.message == "你有新的私信活动")
precondition(banner.receive(refresh, second) == 2, "0.5s and 2s events refresh the same banner")
precondition(banner.events == 2 && banner.title == "乙" && banner.message == "有多条新的私信活动" && banner.pulse == 1)
precondition(DYDMBannerPolicy.shakeActive(pulse: 0, reduceMotion: false) == false, "the first banner uses only the entrance")
precondition(DYDMBannerPolicy.shakeActive(pulse: banner.pulse, reduceMotion: false))
precondition(DYDMBannerPolicy.shakeActive(pulse: banner.pulse, reduceMotion: true) == false)
precondition(banner.receive(refresh, second) == 3, "three rapid events stay on one overlay")
precondition(banner.pulse == 2 && DYDMBannerPolicy.shakeActive(pulse: banner.pulse, reduceMotion: false))
precondition(DYDMBannerPolicy.shakeDistance == 4.5 && DYDMBannerPolicy.shakeScale == 1.025)
precondition(banner.dismiss(scheduledToken: 1) == false, "an older timer cannot dismiss the refreshed banner")
precondition(banner.visible)
precondition(banner.dismiss(scheduledToken: 3), "dismissal follows the latest event")
precondition(!banner.visible && banner.events == 0)
let afterGap = banner.receive(present, first)
precondition(afterGap == 4 && banner.message == "你有新的私信活动", "an event after 4 seconds starts a new banner")
precondition(banner.receive(refresh, ambiguous) == 5)
precondition(banner.title == DYDMBannerPresentation.genericTitle && !banner.enriched, "ambiguous identity clears the previous sender")
banner.invalidate()
precondition(banner.dismiss(scheduledToken: 5) == false)
var plain = DYDMBannerPresentation()
precondition(plain.receive(present, generic) == 1 && plain.title == DYDMBannerPresentation.genericTitle && !plain.enriched)
precondition(plain.receive(refresh, generic) == 2 && plain.message == "有多条新的私信活动" && !plain.enriched)
precondition(DYDMBannerPolicy.decide(input(visible: true, sender: true, alias: true)) == .suppress("alias"))
precondition(plain.receive(.suppress("alias"), second) == nil && plain.pulse == 1, "an alias does not shake the banner")
precondition(DYDMBannerPolicy.decide(input(incoming: 0, visible: true)) == .ignore)
var route = DYDMRouteState()
precondition(route.claim(generation: 3, epoch: 2, enabled: false) == nil, "direct gate off keeps the message list")
route.apply(keep: false, routeID: "conv-a")
precondition(route.route == "conv-a")
let firstTap = route.claim(generation: 3, epoch: 2, enabled: true)
precondition(firstTap?.listID == "conversation:conv-a" && firstTap?.allows(generation: 3, epoch: 2, webUnchanged: true) == true)
precondition(route.allows(firstTap!, generation: 3, epoch: 2, webUnchanged: true))
precondition(route.allows(firstTap!, generation: 3, epoch: 2, webUnchanged: false) == false, "a replaced webview cancels the open")
precondition(route.allows(firstTap!, generation: 4, epoch: 2, webUnchanged: true) == false, "an account change cancels the open")
precondition(route.allows(firstTap!, generation: 3, epoch: 3, webUnchanged: true) == false, "an unexpected navigation cancels the open")
route.apply(keep: true, routeID: "conv-b")
precondition(route.route == "conv-a", "an alias does not replace the route")
route.apply(keep: false, routeID: "conv-a")
precondition(route.route == "conv-a", "another message in the same conversation keeps that route")
route.apply(keep: false, routeID: "conv-b")
let secondTap = route.claim(generation: 3, epoch: 2, enabled: true)
precondition(secondTap?.route == "conv-b" && route.allows(firstTap!, generation: 3, epoch: 2, webUnchanged: true) == false, "a newer conversation replaces the target")
route.apply(keep: false, routeID: nil)
precondition(route.route == nil && route.claim(generation: 3, epoch: 2, enabled: true) == nil, "an ambiguous event drops the old target")
route.apply(keep: false, routeID: "conv-a")
route.apply(keep: false, routeID: "bad id")
precondition(route.route == nil, "a malformed id cannot be reused")
route.apply(keep: false, routeID: "conv-a")
route.cancel()
precondition(route.route == nil && route.claim(generation: 3, epoch: 2, enabled: true) == nil, "logout clears the route before a tap")
precondition(DYDMRouteState.normalized(" conversation") == nil)
precondition(DYDMNotificationSettings.notificationsOn && DYDMNotificationSettings.showsDetail, "notifications and names are always on")
var named = DYDMBannerPresentation()
precondition(named.receive(present, first) == 1 && named.title == "甲" && named.enriched)
named.concealIdentity()
precondition(named.visible && named.title == "有新消息" && !named.enriched && named.events == 1, "turning off names clears the visible banner immediately")
precondition(named.receive(refresh, first) == 2 && named.title == "甲", "a later event can show the name again while the banner is visible")
named.concealIdentity()
precondition(named.receive(refresh, generic) != nil && named.title == "有新消息" && !named.enriched)
var kept = DYDMRouteState()
kept.apply(keep: false, routeID: "conv-a")
named.concealIdentity()
precondition(kept.route == "conv-a", "anonymous mode keeps the direct route")
precondition(DYDMDirectCommit.accept(opened: true, allowed: true))
precondition(DYDMDirectCommit.accept(opened: true, allowed: false) == false, "a finished click is discarded after cancel")
precondition(DYDMDirectCommit.undo(opened: true, allowed: false), "a finished click restores the list after cancel")
precondition(DYDMDirectCommit.undo(opened: false, allowed: false) == false)
precondition(DYDMDirectCommit.accept(opened: false, allowed: true) == false, "a not-ready result cannot commit")
print("PASS DM banner policy: gates, refresh, timer token, alias, generic fallback, motion, direct route")
'''
feed = (root / "DouDuo/DouyinFeedView.swift").read_text()
if feed.count("DYDMBannerModifier(messagesVisible: showMessages, openMessages:") != 2:
    raise SystemExit("default and classic must share the banner tap path")
nav = probe[probe.index("func noteProvisionalNavigation()"):probe.index("func noteDidFinish()")]
if "cancelDirect()" not in nav:
    raise SystemExit("a page navigation must cancel an in-flight direct open")

with tempfile.TemporaryDirectory(prefix="dm-banner-", dir=os.environ["TMPDIR"]) as directory:
    path = Path(directory) / "Banner.swift"
    path.write_text(program)
    binary = path.with_suffix("")
    subprocess.run(["swiftc", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)

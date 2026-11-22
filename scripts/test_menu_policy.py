#!/usr/bin/env python3
"""Read-only menu checks + execute the real Swift feed policy in isolation.

No network, UIKit, simulator, account writes or send callbacks are executed.
SwiftUI wrappers and DYAweme below are test adapters, not API responses.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FEED = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
UPSTREAM_ROOT = FEED[FEED.index("struct DYUpstreamFeedScreen:"):FEED.index("enum DDChromeMode:")]
UPSTREAM_PAGE = FEED[FEED.index("struct DYUpstreamVideoPage:"):FEED.index("struct DYClassicVideoPage:")]
EXTRAS = (ROOT / "DouDuo/DouyinExtras.swift").read_text()


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def menu_content(source, title):
    for match in re.finditer(r"\bMenu \{", source):
        candidate = block(source[match.start():], "Menu")
        tail = source[match.start() + len(candidate):]
        if re.match(r'\s*label:\s*\{\s*Label\("' + re.escape(title) + r'",', tail):
            return candidate
    raise AssertionError("Menu not found: " + title)


class MenuPolicyTests(unittest.TestCase):
    def test_legacy_direction_state_removed(self):
        for token in ("douyin_portrait_ratio_v1", "douyin_portrait_only_v2",
                      "portraitRatio", "mixLabel", "竖屏占比", "douyin.mix",
                      "douyin_short_ratio_portrait_v1", "douyin_short_ratio_landscape_v1",
                      "shortRatio", "isShort(", "wantedShort"):
            self.assertNotIn(token, FEED)

    def test_module_menu_has_messages_and_mine_entries(self):
        menu = block(FEED, "private func minimalModuleButton")
        tail = menu.split('minimalMenuRow("搜索"', 1)[1]
        self.assertIn('minimalMenuRow("信息"', tail)
        self.assertIn('"douyin.module.messages"', tail)
        self.assertIn('minimalMenuRow("我的"', tail)
        info = tail.split('minimalMenuRow("信息"', 1)[1].split('minimalMenuRow("我的"', 1)[0]
        self.assertIn("messagesStartOnMine = false; showMessages = true", info)
        self.assertIn("noticeUnread > 0", info)

    def test_live_module_menu_actions_follow_the_selected_module(self):
        menu = block(FEED, "private func minimalModuleButton")
        live = menu.split("if tab == .live", 1)[1]
        self.assertLess(live.index("我的关注"), live.index('minimalMenuRow("搜索"'))
        self.assertLess(live.index("发现更多"), live.index('minimalMenuRow("搜索"'))
        self.assertIn("douyin.module.live.follow", live)
        self.assertIn("douyin.module.live.discover", live)
        self.assertIn("queueLiveModule(.followedLive)", live)
        self.assertIn("queueLiveModule(.discover)", live)
        after_live = live.split('minimalMenuRow("搜索"', 1)[1]
        self.assertNotIn("我的关注", after_live)
        self.assertNotIn("发现更多", after_live)
        self.assertIn("publishQueuedLiveModule()", menu)
        self.assertNotIn("NotificationCenter", menu)
        room = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
        preview = room.split("if !model.entered", 1)[1].split("if placement.role", 1)[0]
        self.assertIn("previewChrome(in: geo, pane: shown.interaction)", preview)
        self.assertNotIn("DYRailReservedNudge", preview)
        chrome = block(room, "private func previewChrome")
        self.assertIn("containedInsets", chrome)
        self.assertIn("avatarStripInsets", chrome)
        self.assertIn("case .followedLive:", room)
        self.assertNotIn("case .followed:", room)
        followed = room.split("case .followedLive:", 1)[1].split("case .discover:", 1)[0]
        self.assertIn("followStripExpanded = true", followed)
        self.assertNotIn("showFollowLive = true", followed)
        self.assertIn("showDiscover = false", followed)
        discover = room.split("case .discover:", 1)[1].split(".onChange(of: classicPreviewChrome)", 1)[0]
        self.assertIn("followStripExpanded = false", discover)
        self.assertIn("showDiscover = true", discover)
        self.assertIn("live.follow.strip.close", room)
        self.assertIn("DYFollowLiveSheet(bridge: bridge)", room)
        self.assertIn("DYRailReservedNudge()", room.split("private struct DYLiveRoomPage", 1)[1])
        self.assertIn("if classicPreviewChrome", preview)
        self.assertIn("discoverBar", preview)
        self.assertIn("followStrip", preview)
        self.assertLess(preview.index("railFollowDismiss"), preview.index("followStrip(scrollTail:"))
        strip = preview.split("followStrip(scrollTail:", 1)[1]
        self.assertLess(strip.index(".padding(.top, 10)"), strip.index("if showDiscover"))
        dismiss = block(room, "private var railFollowDismiss")
        self.assertIn("DYLivePreviewChrome.minTapHeight", dismiss)
        self.assertNotIn("ddGlassCapsule", dismiss)
        self.assertNotIn("discoverBar", preview.split("} else if followStripExpanded", 1)[1].split("if followStripExpanded", 1)[0])
        self.assertIn("classicPreviewChrome: !chromeMode.usesRail", FEED)
        panel = block(room, "private var discoverPanel")
        self.assertIn("live.discover.close", panel)
        self.assertIn("!classicPreviewChrome", panel)
        self.assertNotIn("发现更多", panel)
        pick = block(room, "private func pickCategory")
        self.assertIn("if !classicPreviewChrome", pick)
        self.assertIn("showDiscover = false", pick)
        self.assertIn("func dismissPreviewOverlays()", room)

    def test_top_bar_icons_and_hit_targets(self):
        top = block(UPSTREAM_ROOT, "private func topBarRow")
        self.assertIn("ForEach(DYTab.allCases", top)
        tabs = block(FEED, "enum DYTab:")
        for title in ("关注", "推荐", "直播"):
            self.assertIn('"' + title + '"', tabs)
        # 老板 2026-11-19：顶栏「信息」要有字，点它进信息页
        self.assertIn('Text("信息")', top)
        self.assertIn("showMessages = true", top)
        self.assertNotIn("myUser?.name", top)
        self.assertNotIn("showName", top)
        self.assertIn("noticeUnread > 0", top)
        self.assertIn("theme.status.danger", top)
        self.assertEqual(top.count(".frame(minWidth: 44, minHeight: 44)"), 2)

    def test_current_item_menu(self):
        menu = block(UPSTREAM_PAGE, "private func moreMenu")
        quick = block(menu, "ControlGroup")
        self.assertIn("DYForwardMenu(item: item, bridge: bridge, foreground: fg)", quick)
        self.assertIn('"下载"', quick)
        self.assertNotIn("ShareLink", menu)
        self.assertNotIn("danmaku", quick.lower())
        # 2026-11-14 老板定：不感兴趣放在转发和下载中间，跟它们同色（不是红色 destructive）
        self.assertLess(quick.index("DYForwardMenu"), quick.index('"不感兴趣"'))
        self.assertLess(quick.index('"不感兴趣"'), quick.index('"下载"'))
        self.assertNotIn("role: .destructive", quick)
        self.assertEqual(menu.count('"不感兴趣"'), 1)
        # 表层：倍速 / 静音 / 听书 / 自动连播 + 发弹幕；刷新推荐、弹幕设置、界面都只在设置页
        for token in ('"douyin.quick.speed"', "$muted", "$bgPlay", "$autoNext", '"douyin.quick.autonext"',
                      '"发弹幕"', "dm.showInput = true", "danmakuFocused = true", "moreExtras"):
            self.assertIn(token, menu)
        for gone in ("DYDanmakuOptions", "$chromeModeRaw", '"刷新推荐"', "界面模式"):
            self.assertNotIn(gone, menu)
        self.assertLess(menu.index('"发弹幕"'), menu.index("moreExtras"))

    def test_danmaku_settings_only_in_settings_screen(self):
        self.assertNotIn("struct DYDanmakuOptions", EXTRAS)
        screen = (ROOT / "DouDuo/DYSettingsScreen.swift").read_text()
        for token in ('Toggle("显示弹幕"', 'Picker("弹幕密度"', 'Toggle("10 秒内重复弹幕去重"'):
            self.assertIn(token, screen)

    def test_settings_paths_and_duration_preferences(self):
        # 2026-11-14 老板定：「更多」最后一节只有「设置」，点进完整设置页；刷新推荐 / 弹幕 / 界面都在设置页。
        upstream = block(UPSTREAM_ROOT, "private func moreExtrasMenu")
        classic = block(FEED, "    private var moreExtrasMenu: some View")
        for menu in (upstream, classic):
            self.assertIn("DYSettingsButton()", menu)
            for gone in ("DYHashtagFilterButton", "Label(\"设置\"", "$cacheCount", "播放设置", "内容偏好",
                         '"刷新推荐"', "DYChromeModePicker", "DYDanmakuOptions"):
                self.assertNotIn(gone, menu)
            self.assertNotIn("@State", menu)
        # 经典顶栏「更多」表层：静音 / 听书 / 自动连播
        self.assertIn("$muted", classic)
        self.assertIn("$bgPlay", classic)
        self.assertIn("$autoNext", classic)
        self.assertLess(classic.index("$bgPlay"), classic.index("DYSettingsButton()"))
        self.assertNotIn("struct DYChromeModePicker", FEED)
        screen = (ROOT / "DouDuo/DYSettingsScreen.swift").read_text()
        # 老板 11-19 重排：界面 → 播放与弹幕 → 推荐与内容 → 评论与私信 → 缓存与离线 → 账号 → 关于
        order = ['Text("界面")', 'Text("播放与弹幕")', 'Text("推荐与内容")', 'Text("评论与私信")',
                 'Text("缓存与离线")', 'Text("账号")', 'Text("关于")']
        for section in ['Label("刷新推荐"'] + order:
            self.assertIn(section, screen)
        idx = [screen.index(t) for t in order]
        self.assertEqual(idx, sorted(idx), "设置分组顺序")
        # 2026-11-14 老板定：表层菜单已有的（静音 / 铺满 / 听书 / 自动连播）设置页不重复；短视频占比删除
        for gone in ('"douyin_autoplay_v1"', '"douyin_muted_v1"', '"douyin_autofit_v1"', '"douyin_bg_play_v1"',
                     "short_ratio", "短视频占比", "ratioChoices", 'Toggle("静音"', 'Toggle("自动连播"', 'Toggle("铺满宽度',
                     'Toggle("听书模式', "$autoNext", "$muted", "$autoFit", "$backgroundPlay"):
            self.assertNotIn(gone, screen)
        self.assertNotIn('"douyin_wide_landscape_v1"', screen)
        self.assertNotIn('Toggle("横屏时只放横屏内容"', screen)
        for token in ("DYVideoAmbient.key",
                      "DYHashtagFilterScreen(currentTags: [], embedded: true)",
                      '"douyin_danmaku_v1"', "DYDanmakuPolicy.densityKey", "DYDanmakuPolicy.deduplicateKey",
                      "DYVideoCache.countKey", "DYStorageScreen(", "DYOfflineDownloadScreen(candidateSource:", "DDUpdateChecker.repoURL",
                      "DDAppVersion.display", "DDChromeMode.key"):
            self.assertIn(token, screen)
        self.assertEqual(FEED.count(".environment(\\.dyOpenSettings, { showSettings = true })"), 2)
        self.assertEqual(FEED.count("onRefresh: { Task { await refreshRecommendations() } }"), 2)
        # 经典长按面板只留当前视频相关：铺满 / 静音 / 听书 / 自动连播 / 不感兴趣 / 倍速 / 发弹幕
        panel = (ROOT / "DouDuo/DYVideoOptionsPanel.swift").read_text()
        for token in ('"douyin.options.fit"', '"douyin.options.muted"', '"douyin.options.bgplay"', '"douyin.options.autonext"',
                      '"douyin.dislike"', '"douyin.options.rate.', '"发弹幕"'):
            self.assertIn(token, panel)
        for gone in ("ambientLevel", "landscapeOnly", "portraitRatio", "landscapeRatio",
                     "danmakuEnabled", "弹幕密度", "内容偏好"):
            self.assertNotIn(gone, panel)
        load = block(FEED, "func loadMore(_ bridge:")
        self.assertIn("added += fill(want - added)", load)
        # 2026-11-22：推荐按服务端原序进入播放列表，不再按横竖屏挑片、重排或淘汰。
        self.assertIn("items.append(contentsOf: pool.prefix(n))", FEED)
        self.assertNotIn("landscapeOnlyActive", FEED)
        self.assertNotIn("portraitTarget", FEED)
        self.assertNotIn("func remix(after:", FEED)

    def test_feed_uses_recommend_endpoint_only(self):
        # 2026-11-14 老板定：只保留网页首页「推荐」(tab/feed)，精选(module/feed)删掉，也不给切换
        fetch = block(FEED, "func fetchFeed()")
        self.assertIn("Self.tabFeedJS", fetch)
        self.assertNotIn("feedJS,", fetch.replace("tabFeedJS", ""))
        self.assertIn("/aweme/v1/web/tab/feed/", FEED)
        self.assertNotIn("private static let feedJS", FEED)
        self.assertNotIn("DYFeedSource", FEED)

    def test_execute_extracted_swift_model(self):
        # Compile production properties and server-order fill policy, excluding all network code.
        model = FEED[FEED.index("final class DYFeedModel:"):FEED.index("    func loadMore(_ bridge:")]
        model += "}\n"
        adapters = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
}
let suiteName = "DouDuo.MenuPolicyRegression." + UUID().uuidString
let preferences = UserDefaults(suiteName: suiteName)!
@propertyWrapper struct AppStorage<Value> {
    let key: String
    let fallback: Value
    init(wrappedValue: Value, _ key: String) { self.key = key; fallback = wrappedValue }
    var wrappedValue: Value {
        get { preferences.object(forKey: key) as? Value ?? fallback }
        nonmutating set { preferences.set(newValue, forKey: key) }
    }
}
// Explicit in-memory policy fixtures, not captured or synthesized platform responses.
struct DYAweme {
    let id: String
    var desc: String = ""
    var hashtagNames: [String]? = nil
    var images: [String] = []
    var isTallFrame: Bool = false
    var duration: Double = 60
    var live: Int? = nil  // 推荐直播条目（只用来判空，见 withoutDisabledLive）
    var isAd: Bool? = nil  // 推荐广告标记（withoutDisabledLive 按「推荐里显示广告」过滤）
}
'''
        checks = r'''
defer { preferences.removePersistentDomain(forName: suiteName) }
// 混合横屏、竖屏和图文的输入必须按服务端原序进入播放列表。
let feed = DYFeedModel()
let ids = (0..<24).map { "r\($0)" }
feed.pool = ids.enumerated().map { offset, id in
    DYAweme(id: id, images: offset % 7 == 0 ? ["fixture"] : [], isTallFrame: offset % 3 == 0)
}
precondition(feed.fill(7) == 7)
precondition(feed.items.map(\.id) == Array(ids.prefix(7)), "first fill reordered: \(feed.items.map(\.id))")
precondition(feed.pool.map(\.id) == Array(ids.dropFirst(7)), "pool order changed after first fill")
precondition(feed.fill(100) == 17)
precondition(feed.items.map(\.id) == ids, "server order changed: \(feed.items.map(\.id))")
precondition(feed.pool.isEmpty)
precondition(feed.fill(1) == 0)

// 取片数量只受剩余候选数量限制，与横竖比例无关。
let mixed = DYFeedModel()
mixed.pool = [
    DYAweme(id: "portrait-0", isTallFrame: true),
    DYAweme(id: "landscape-1", isTallFrame: false),
    DYAweme(id: "portrait-2", isTallFrame: true),
    DYAweme(id: "gallery-3", images: ["fixture"]),
    DYAweme(id: "landscape-4", isTallFrame: false),
]
precondition(mixed.fill(5) == 5)
precondition(mixed.items.map(\.id) == ["portrait-0", "landscape-1", "portrait-2", "gallery-3", "landscape-4"])
print("PASS server order preserved across mixed portrait, landscape and gallery content")
'''
        scratch = Path(tempfile.gettempdir())
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="menu-policy-", dir=scratch) as folder:
            source = Path(folder) / "Policy.swift"
            hashtags = (ROOT / "DouDuo/DYHashtag.swift").read_text()
            filters = (ROOT / "DouDuo/DYHashtagFilter.swift").read_text()
            fit = (ROOT / "DouDuo/DYVideoFit.swift").read_text()
            source.write_text(fit + adapters + hashtags + filters + model + checks)
            result = subprocess.run(["swift", str(source)], text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)

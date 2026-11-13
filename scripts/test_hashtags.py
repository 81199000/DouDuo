#!/usr/bin/env python3
"""Execute production hashtag parsing, persistence and recommendation filtering in Swift."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class HashtagTests(unittest.TestCase):
    def test_swift_filter_and_feed_ingress(self):
        source = (ROOT / 'DouDuo/DouyinFeedView.swift').read_text()
        model = source[source.index('struct DYAweme:'):source.index('/// 点赞/收藏的结果')]
        feed = source[source.index('@MainActor\nfinal class DYFeedModel'):source.index('private struct DYFeedHostFrameKey')]
        stubs = r'''
@MainActor final class DouyinBridge {
    var calls = 0
    var results: [DYAweme] = []
    var beforeResponse: (() -> Void)?
    func fetchFeed() async throws -> (items: [DYAweme], hasMore: Bool) {
        calls += 1
        beforeResponse?()
        return (results, true)
    }
}
enum DYLiveModel { static func log(_ text: String) {} }
private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { min(max(self, lo), hi) }
}
'''
        harness = r'''
@main struct Verify {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print((ok ? "PASS " : "FAIL ") + label)
            if !ok { failures += 1 }
        }
        let caption = "日常 #猫咪，#旅行。＃Travel #旅行#摄影 #猫🐱 #cafe\u{301} # #_生活"
        let names = DYHashtag.names(in: caption)
        check(names == ["猫咪", "旅行", "Travel", "摄影", "猫🐱", "cafe\u{301}", "_生活"], "Unicode, punctuation, adjacent, duplicate and bare hashes")
        for match in DYHashtag.matches(in: caption) {
            check(String(caption[match.range]).hasPrefix("#") || String(caption[match.range]).hasPrefix("＃"), "valid original string range")
        }
        let special = "教程 #C++ #New York #猫咪"
        check(DYHashtag.names(in: special, knownNames: ["C++", "New York"]) == ["C++", "New York", "猫咪"], "platform tags preserve punctuation and spaces")
        check(DYHashtag.names(in: "日常 #👩‍💻") == ["👩‍💻"], "joined emoji remains a complete tag")
        for name in ["旅行", "猫🐱", "👩‍💻", "C++", "New York", "a&b?/100%"] {
            check(DYHashtag.searchURL(for: name).flatMap(DYHashtag.searchName) == name, "search URL round trip: " + name)
        }
        check(DYHashtag.searchName(from: URL(string: "https://example.com/?tag=test")!) == nil, "external links rejected")
        var filter = DYHashtagFilter()
        check(filter.add("  ＃Ｔｒａｖｅｌ  ") == .added, "optional prefix, width and trimming")
        check(filter.add("travel") == .duplicate, "case/width duplicate rejected")
        for input in ["", "  ", "#", "##猫", "#猫 #狗", "!!!", "猫\n狗"] {
            check(filter.add(input) == .invalid, "invalid input rejected: " + input)
        }
        check(filter.blocks(description: "随拍 #TRAVEL"), "case insensitive block")
        check(!filter.blocks(description: "我喜欢 travel") && !filter.blocks(description: "#traveler"), "not a prose/substring filter")
        let restored = DYHashtagFilter(rawValue: filter.rawValue)
        check(restored.tags == filter.tags && restored.blocks(description: "#Travel"), "JSON storage round trip")
        check(DYHashtagFilter(rawValue: "bad json").tags.isEmpty, "damaged storage safely ignored")
        filter.remove("Travel")
        check(filter.tags.isEmpty, "remove by normalized key")

        func item(_ id: String, _ caption: String, tags: [String]? = nil) -> DYAweme {
            DYAweme(id: id, desc: caption, width: 1080, height: 1920, duration: 30,
                play: "https://example.com/" + id + ".mp4", cover: nil, images: [],
                author: .init(name: "测试", avatar: nil, secUid: nil),
                stats: .init(digg: 0, comment: 0, collect: 0, share: 0), music: "", userDigged: nil,
                isCollect: nil, hashtagNames: tags)
        }
        let cat = item("cat", "#猫")
        let kitten = item("kitten", "#猫咪")
        let prose = item("prose", "一只猫")
        let metadata = item("metadata", "今日记录", tags: ["猫"])
        let defaults = UserDefaults(suiteName: "DouDuoHashtagTests." + UUID().uuidString)!
        defer { defaults.removeObject(forKey: DYHashtagFilter.storageKey) }
        filter = DYHashtagFilter(); _ = filter.add("猫")
        defaults.set(filter.rawValue, forKey: DYHashtagFilter.storageKey)
        let model = DYFeedModel(defaults: defaults)
        check(model.allowedRecommendations([cat, kitten, prose, metadata]).map(\.id) == ["kitten", "prose"], "caption and platform metadata, whole tags only")
        model.seedPool([cat, kitten, metadata]); model.fill(6, relaxed: true)
        check(model.items.map(\.id) == ["kitten"], "cached seed filtered")
        model.items = [prose, cat, kitten, metadata]; model.pool = [cat, metadata]
        check(model.applyHashtagFilter(currentID: "cat") == "kitten", "current blocked video advances to next survivor")
        check(model.items.map(\.id) == ["prose", "kitten"] && model.pool.isEmpty, "already loaded and queued videos removed")
        check(model.applyHashtagFilter(currentID: "prose") == "prose", "unblocked active video retained")
        model.pool = [cat, kitten]; model.fill(6, relaxed: true)
        check(!model.items.contains(where: { $0.id == "cat" }), "relaxed ratio never bypasses tag filter")
        model.reset(); model.pool = [cat, kitten]
        check(model.applyHashtagFilter(currentID: nil) == "kitten", "empty list replenished from allowed pool")
        model.reset()
        let bridge = DouyinBridge(); bridge.results = [cat, metadata]
        await model.loadMore(bridge)
        check(model.items.isEmpty && bridge.calls == 8 && !model.loading && model.error != nil, "fully filtered feed bounded to eight pages and exposes empty state")
        defaults.removeObject(forKey: DYHashtagFilter.storageKey)
        bridge.results = [cat]
        bridge.beforeResponse = { defaults.set(filter.rawValue, forKey: DYHashtagFilter.storageKey) }
        await model.loadMore(bridge)
        check(model.items.isEmpty, "in-flight response uses newest blocklist")
        bridge.beforeResponse = nil
        defaults.removeObject(forKey: DYHashtagFilter.storageKey)
        await model.loadMore(bridge)
        check(model.items.map(\.id) == ["cat"], "unblocking permits future recommendations")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cat)) as! [String: Any]
        json.removeValue(forKey: "hashtagNames")
        let legacy = try JSONDecoder().decode(DYAweme.self, from: JSONSerialization.data(withJSONObject: json))
        check(legacy.hashtagNames == nil && legacy.hashtags == ["猫"], "old cached sessions decode and use caption fallback")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='douduo-hashtags-') as d:
            d = Path(d)
            test = d / 'Verify.swift'
            test.write_text('import Foundation\nimport SwiftUI\nimport Combine\n' + model + stubs + feed + harness)
            subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(d/'modules'),
                str(ROOT/'DouDuo/DYHashtag.swift'), str(ROOT/'DouDuo/DYHashtagFilter.swift'),
                str(test), '-o', str(d/'verify')], check=True)
            subprocess.run([str(d/'verify')], check=True)

    def test_observed_search_login_response(self):
        source = (ROOT / 'DouDuo/DouyinExtras.swift').read_text()
        feed = (ROOT / 'DouDuo/DouyinFeedView.swift').read_text()
        # Use exactly the production decoder and response validation method.
        page = next(line for line in source.splitlines() if line.startswith('private struct DYListPage:'))
        method = source[source.index('    private func list('):source.index('    func selfSecUid()')].replace('private func list', 'func list')
        error = feed[feed.index('enum DYError:'):feed.index('// MARK: - 签名代理')]
        harness = r'''
import Foundation
struct DYAweme: Decodable { let id: String }
__PAGE__
__ERROR__
final class DouyinBridge {
    static let searchJS = "search"
    var response = Data()
    func call(_ js: String, args: [String: Any]) async throws -> Data { response }
__METHOD__
}
@main struct Verify {
    static func main() async throws {
        let bridge = DouyinBridge()
        for (code, message, expected) in [
            (2483, "请先登录，再继续搜索吧", "抖音未登录"),
            (8, "", "抖音未登录"),
            (10001, "完成验证后重试", "完成验证后重试")
        ] {
            bridge.response = try JSONSerialization.data(withJSONObject: ["status": 200, "code": code,
                "msg": message, "items": [], "cursor": "0", "hasMore": false])
            do {
                _ = try await bridge.list("search", [:])
                fatalError("API failure must not be presented as an empty result")
            } catch {
                precondition(error.localizedDescription.contains(expected))
            }
        }
        bridge.response = Data(#"{"status":200,"code":0,"items":[],"cursor":"0","hasMore":false}"#.utf8)
        let empty = try await bridge.list("search", [:])
        precondition(empty.items.isEmpty)
        bridge.response = Data(#"{"status":-3,"items":[],"cursor":"0","hasMore":false}"#.utf8)
        do {
            _ = try await bridge.list("search", [:])
            fatalError("XHR hard timeout must not be reported as an HTTP or login failure")
        } catch {
            precondition(error.localizedDescription == "搜索请求超时，请稍后重试")
        }
        bridge.response = Data(#"{"status":200,"code":0,"items":[{"id":"server-video"}],"cursor":"24","hasMore":true}"#.utf8)
        let success = try await bridge.list("search", [:])
        precondition(success.items.first?.id == "server-video")
        print("PASS observed 2483 login and -3 timeout responses, legacy auth, other search errors, genuine empty and successful results")
    }
}
'''
        harness = harness.replace('__PAGE__', page).replace('__ERROR__', error).replace('__METHOD__', method)
        with tempfile.TemporaryDirectory(prefix='douduo-search-response-') as folder:
            folder = Path(folder)
            (folder / 'Verify.swift').write_text(harness)
            subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                            str(folder / 'Verify.swift'), '-o', str(folder / 'verify')], check=True)
            subprocess.run([str(folder / 'verify')], check=True)

    def test_bridge_mapper_preserves_tag_names(self):
        script = r'''
const fs = require('fs'), vm = require('vm');
const source = fs.readFileSync(process.argv[1], 'utf8');
const js = source.match(/static let requestJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const a = {aweme_id:'tag-fixture', desc:'#猫 #C++',video:{},author:{},statistics:{},text_extra:[{hashtag_name:'猫'},{hashtag_name:'C++'},{user_id:'1'}],cha_list:[{cha_name:'猫'},{cha_name:'New York'}]};
const mapped = vm.runInNewContext(js + '\nmapA(a)', {a, URLSearchParams});
if (JSON.stringify(mapped.hashtagNames) !== JSON.stringify(['猫','C++','New York'])) throw new Error(JSON.stringify(mapped));
a.text_extra = undefined; a.cha_list = undefined;
if (vm.runInNewContext(js+'\nmapA(a)',{a,URLSearchParams}).hashtagNames.length) throw new Error('missing metadata');
console.log('PASS bridge mapper and absent metadata');
'''
        subprocess.run(['node','-e',script,str(ROOT/'DouDuo/DouyinFeedView.swift')],check=True)

if __name__ == '__main__': unittest.main()

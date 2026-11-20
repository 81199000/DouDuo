#!/usr/bin/env python3
"""私信名字旁的关系标签：判定与抖音网页版关注按钮同一套（follow_status 我→对方 / follower_status 对方→我）。"""
import pathlib, re, subprocess, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CELL = (ROOT / "DouDuo" / "DYConversationCell.swift").read_text()
MSG = (ROOT / "DouDuo" / "DouyinMessages.swift").read_text()


class RelationLabel(unittest.TestCase):
    def test_mapping(self):
        enum = CELL[CELL.index("enum DYRelationLabel"):CELL.index("struct DYRelationTag")]
        main = "import Foundation\n" + enum + r'''
func check(_ c: Bool, _ m: String) { if !c { print("FAIL", m); exit(1) } }
check(DYRelationLabel.from(follow: 0, follower: 1) == .fan, "对方关注我、我没关注 → 粉丝")
check(DYRelationLabel.from(follow: 2, follower: 1) == .mutual, "互关")
check(DYRelationLabel.from(follow: 2, follower: nil) == .mutual, "follow_status=2 本身就是互关")
check(DYRelationLabel.from(follow: 1, follower: 1) == .mutual, "双向已关注也算互关")
check(DYRelationLabel.from(follow: 1, follower: 0) == nil, "我单向关注：不打标")
check(DYRelationLabel.from(follow: 0, follower: 0) == nil, "互不关注：不打标")
check(DYRelationLabel.from(follow: nil, follower: nil) == nil, "没查到：不打标")
check(DYRelationLabel.fan.text == "粉丝" && DYRelationLabel.mutual.text == "相互关注", "文案")
print("relation ok")
'''
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "main.swift"
            p.write_text(main)
            r = subprocess.run(["swift", str(p)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("relation ok", r.stdout)

    def test_wiring(self):
        self.assertIn("u.follower_status", MSG)
        self.assertIn("relation: cache.relationLabel(row)", MSG)
        # 我已关注对方 → 头像右下红心
        self.assertIn("following: cache.isFollowing(row)", MSG)
        self.assertIn('Image(systemName: "heart.fill")', CELL)
        self.assertIn("var follower: [String: Int]?", MSG)
        # 陌生人列表也带 sec_uid，并且会去查关系
        self.assertIn("toParticipantSecUserId", MSG[MSG.index("collectStrangerJS = "):])
        self.assertIn("cache.resolveFollow(rows.compactMap(\\.sec))", MSG)


if __name__ == "__main__":
    unittest.main()

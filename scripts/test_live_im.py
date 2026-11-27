#!/usr/bin/env python3
"""直播间弹幕数据层：PushFrame / im/fetch 解 gzip + protobuf，弹幕 / 礼物 / 表情 / 进场 / 点赞 / 关注 / 下播，礼物连击合并。

Run: python3 scripts/test_live_im.py -v
不联网，也不启动模拟器。夹具是手写的 protobuf，不含真实数据。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo/DYLiveIM.swift"
CHAT = ROOT / "DouDuo/DouyinLiveChat.swift"


class LiveIMTests(unittest.TestCase):
    def test_decoder_suite(self):
        with tempfile.TemporaryDirectory(prefix="douduo-live-im-") as tmp:
            binary = Path(tmp) / "live-im"
            built = subprocess.run(["swiftc", "-parse-as-library", "-D", "LIVE_IM_MAIN", str(SOURCE), "-o", str(binary)],
                                   check=False, capture_output=True, text=True)
            if built.returncode != 0:
                self.fail(built.stdout + built.stderr)
            ran = subprocess.run([str(binary)], check=False, capture_output=True, text=True)
        if ran.returncode != 0:
            self.fail(ran.stdout + ran.stderr)
        self.assertIn("DYLiveIMTests passed", ran.stdout)

    def test_hook_is_passive_and_installed_early(self):
        src = CHAT.read_text()
        hook = src.split("static let imHookJS", 1)[1].split('#"""', 1)[1].split('"""#', 1)[0]
        self.assertIn("webcast\\/im\\/(push|fetch)", hook)
        self.assertNotIn(".send(", hook.replace("send.apply", ""), "只读：不往 WebSocket 里发任何东西")
        self.assertIn("imHookJS, injectionTime: .atDocumentStart", src, "要抢在页面建 WebSocket 之前装上")
        self.assertIn("!self.imActive", src, "截到原始数据后不再重复加页面文字")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""账号切换快照的纯逻辑：只留安全 SDK 的 localStorage、原生登录三样齐全、合并不冲掉旧快照、日志不含原文。

Run: python3 scripts/test_account_snapshot.py -v
不联网，也不启动模拟器。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo/DYAccountSnapshot.swift"
STORE = ROOT / "DouDuo/DYAccounts.swift"


class AccountSnapshotTests(unittest.TestCase):
    def test_logic_suite(self):
        with tempfile.TemporaryDirectory(prefix="douduo-account-snapshot-") as tmp:
            binary = Path(tmp) / "account-snapshot"
            built = subprocess.run(
                ["swiftc", "-parse-as-library", "-D", "ACCOUNT_SNAPSHOT_MAIN", str(SOURCE), "-o", str(binary)],
                check=False, capture_output=True, text=True)
            if built.returncode != 0:
                self.fail(built.stdout + built.stderr)
            ran = subprocess.run([str(binary)], check=False, capture_output=True, text=True)
        if ran.returncode != 0:
            self.fail(ran.stdout + ran.stderr)
        self.assertIn("DYAccountSnapshotTests passed", ran.stdout)

    def test_switch_restores_whole_snapshot(self):
        src = STORE.read_text()
        switch = src.split("func switchTo(", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("refreshCurrentSnapshot", switch, "切走前先存好当前账号")
        self.assertIn("clearNativeLogin", switch, "切换要换掉原生登录那一份")
        self.assertIn("restoreWebStorage", switch, "切换要写回网页密钥")
        self.assertIn("importNativeLogin", switch, "切换要写回原生登录")
        sign_out = src.split("func signOut(", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("clearNativeLogin", sign_out, "退出也要清原生登录，否则原生请求还是登录状态")
        remove = src.split("func remove(", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("extrasAccount", remove, "移除账号连快照一起删")


if __name__ == "__main__":
    unittest.main()

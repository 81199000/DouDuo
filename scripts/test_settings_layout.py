#!/usr/bin/env python3
"""设置页：GuoDuo 同款图标行；精简后的条目位置与默认值。"""
import re, sys, pathlib
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
s = (R / "DYSettingsScreen.swift").read_text()
feed = (R / "DouyinFeedView.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

check("struct DDSettingRow" in s and "RoundedRectangle(cornerRadius: 7, style: .continuous)" in s, "图标行与 GuoDuo 同款")
check('Toggle("环境光", isOn: ambientOn)' in s and "DYVideoAmbient.onLevel" in s, "环境光是开关")
for gone in ("刷新推荐", "不再推荐看过的视频", "Wi-Fi 省流量", "蜂窝数据省流量", "预缓存数量", "网页版 / 登录",
             "应用内私信通知", "通知里显示会话名称", "onOpenWeb", "onRefresh", "DYSettingInfo"):
    check(gone not in s, f"已去掉：{gone}")
for gone in ("横屏时只放横屏内容", "竖屏时固定 70%", "10 秒内重复弹幕去重", "用网页评论框发送", "点回复时自动弹出键盘",
             "边看边缓存", "清空看过记录", "高级设置", "private var advanced"):
    check(gone not in s, f"已去掉：{gone}")
check('"按关键词屏蔽视频"' in s and 'Toggle("离开应用时自动画中画"' in s, "关键词屏蔽、自动画中画留在设置主页")
check("let landscapeWhenWide = false" in feed or "var landscapeWhenWide = false" in feed, "横屏只放横屏固定关")
check("var portraitMix = false" in feed and "@AppStorage(\"douyin_portrait_mix_v1\")" not in feed, "70% 竖屏固定关")
sys.exit(1 if fails else 0)

"""VLC 播放器最后一次释放不能发生在主线程（2026-11-21 Duo 两次卡死被系统看门狗杀：
主线程 libvlc_media_player_destroy → pthread_join，VLC 线程卡在 input_Close / ca_Flush）。"""
import pathlib, re
s = (pathlib.Path(__file__).resolve().parent.parent / "DouDuo/VLCPlayerBridge.swift").read_text()
m = re.search(r"\n    deinit \{(.*?)\n    \}\n", s, re.S)
assert m, "VLCPlayerController 要有 deinit 接管释放"
body = m.group(1)
assert "mediaPlayer = nil" in body, "deinit 里控制器要先放手"
assert "DispatchQueue.global" in body and "release.player = nil" in body, "最后一次释放要在后台线程"
assert body.index("release.player = player") < body.index("mediaPlayer = nil"), "先交给 release 再放手"
assert "private(set) var mediaPlayer: VLCMediaPlayer!" in s
print("ok vlc release off main")

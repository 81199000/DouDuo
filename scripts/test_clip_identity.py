"""DDClipIf 两种状态必须是同一种视图（不能 if/else 换分支）
关时的放大量要小（±100000 的超大裁剪真机渲染成黑屏，95ef04d 已回滚）。"""
import pathlib, re
s = (pathlib.Path(__file__).resolve().parent.parent / "DouDuo/DYCommentStage.swift").read_text()
m = re.search(r"struct DDClipIf: ViewModifier \{(.*?)\n\}", s, re.S)
assert m, "DDClipIf 不见了"
body = m.group(1)
assert not re.search(r"\bif on\b", body), "DDClipIf 不能用 if/else 换视图类型（会重建播放器、从头播）"
assert "clipShape(" in body, "要一直挂着裁剪"
shape = re.search(r"struct DDPaneClipShape: Shape \{(.*?)\n\}", s, re.S)
scope = body + (shape.group(1) if shape else "")
big = [int(x) for x in re.findall(r"-\s*(\d+)", scope)]
assert big and max(big) <= 1000, f"关评论时的放大量 {big} 太大（超大裁剪真机黑屏）"
# 开评论时上下也要外扩
assert shape and "dy: -" in shape.group(1), "开评论时上下也要外扩"
print("ok clip identity")

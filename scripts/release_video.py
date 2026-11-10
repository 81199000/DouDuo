#!/usr/bin/env python3
"""发布短片渲染器：纯构图（无 App 界面）+ 中文配音 + 烧录字幕，竖屏 1080x1920。

用法：改 SCENES 里的文案/参数后 `/usr/local/bin/python3 scripts/release_video.py`。
依赖：PIL、ffmpeg、macOS `say`（Tingting 中文音色）、Hiragino Sans GB 字体。
音频先按句合成测时长，再定每幕帧数，字幕随幕烧进画面，因此音画天然同步。
"""
import json
import math
import shutil
import subprocess
import wave
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1080, 1920, 30
ROOT = Path(__file__).resolve().parent
FRAMES = ROOT / "frames"
AUDIO = ROOT / "audio"
VOICE = "Tingting"
RATE = 175

INK = (243, 248, 251)
MUTED = (150, 172, 186)
ACCENT = (53, 224, 200)
WARM = (255, 184, 107)
DEEP = (6, 15, 24)

FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(size, index=0):
    return ImageFont.truetype(FONT_PATH, size, index=index)


F = {
    "hero": font(300),
    "h1": font(104),
    "h2": font(76),
    "lead": font(52),
    "body": font(40),
    "chip": font(34),
    "small": font(30),
    "mono": font(38),
    "sub": font(46),
}

SCENES = [
    dict(
        kind="title", eyebrow="DOUDUO 1.3.8", head=["DouDuo", "1.3.8"],
        say="抖音客户端 DouDuo，更新到 1.3.8 了。",
    ),
    dict(
        kind="timeline", eyebrow="这次走了多远", head=["从 1.3.4", "到 1.3.8"],
        say="从 1.3.4 到 1.3.8，四个版本，四十处改动。",
    ),
    dict(
        kind="feature", art="share", eyebrow="01 · 转发",
        head=["转发，", "跟原版一样了"],
        chips=["原生浮层", "真实好友", "官方作品卡片", "发送即确认"],
        say="最明显的是转发。现在跟原版一样，是浮层，真实好友，官方作品卡片，发出去立刻确认。",
    ),
    dict(
        kind="feature", art="cache", eyebrow="02 · 缓存",
        head=["朋友和会话", "打开就有"],
        chips=["本地缓存", "只扫增量", "无变化不写盘"],
        say="朋友和会话都做了本地缓存，打开就有数据，后台只扫描变化的部分。",
    ),
    dict(
        kind="feature", art="danmaku", eyebrow="03 · 弹幕",
        head=["弹幕收在", "上方三分之一"],
        chips=["三档密度", "十秒去重", "默认开启"],
        say="弹幕收在画面上方三分之一，密度三档，重复的内容十秒内不再重复出现。",
    ),
    dict(
        kind="feature", art="grid", eyebrow="04 · 直播",
        head=["分类，换成", "网页真实分区"],
        chips=["精选", "关注", "游戏", "音乐", "生活", "运动"],
        say="直播分类换成网页真实分区，发言也走官方流程，不会再假回显。",
    ),
    dict(
        kind="feature", art="rail", eyebrow="05 · 界面",
        head=["右侧栏", "顺序对齐原版"],
        chips=["赞 → 评论 → 收藏 → 搜索", "图标间距收紧"],
        say="右侧栏顺序对齐原版，赞、评论、收藏，间距也收紧了。",
    ),
    dict(
        kind="feature", art="menu", eyebrow="06 · 设置",
        head=["菜单分层", "竖屏固定七成"],
        chips=["播放", "内容", "缓存", "账号", "关于"],
        say="设置菜单按场景分了层，竖屏比例固定在七成，横屏规则保留。",
    ),
    dict(
        kind="feature", art="badges", eyebrow="07 · 细节",
        head=["发布时间", "AI 声明", "发言回执"],
        chips=["旧缓存兼容", "不再假回显"],
        say="播放信息补上发布时间和 AI 声明，旧缓存也能正常显示。",
    ),
    dict(
        kind="download", eyebrow="下载",
        head=["两个下载地址"],
        say="下载地址两个：GitHub 搜 81199000 斜杠 DouDuo；国内用 Gitee，remon8 斜杠 douduo。",
    ),
    dict(
        kind="end", eyebrow="DOUDUO", head=["DouDuo 1.3.8"],
        say="下载未签名安装包，自己签名安装，需要 iOS 十七以上。",
    ),
]

LINKS = [
    ("GitHub", "github.com/81199000/DouDuo", "releases/latest"),
    ("Gitee · 国内", "gitee.com/remon8/douduo", "releases"),
]

LEAD_IN, TAIL = 0.35, 0.6


def ease_out(t):
    return 1 - (1 - t) ** 3


def clamp(t):
    return max(0.0, min(1.0, t))


def gradient_bg():
    img = Image.new("RGB", (W, H), DEEP)
    d = ImageDraw.Draw(img)
    stops = [(0.0, (4, 10, 17)), (0.42, (9, 27, 39)), (0.72, (8, 22, 33)), (1.0, (4, 9, 15))]
    for y in range(H):
        p = y / (H - 1)
        for i in range(len(stops) - 1):
            if stops[i][0] <= p <= stops[i + 1][0]:
                t = (p - stops[i][0]) / (stops[i + 1][0] - stops[i][0])
                c = tuple(int(stops[i][1][k] + (stops[i + 1][1][k] - stops[i][1][k]) * t) for k in range(3))
                d.line([(0, y), (W, y)], fill=c)
                break
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * 0.42, -H * 0.22, W * 1.55, H * 0.42], fill=ACCENT + (26,))
    gd.ellipse([-W * 0.45, H * 0.55, W * 0.55, H * 1.15], fill=WARM + (16,))
    glow = glow.filter(ImageFilter.GaussianBlur(180))
    base = Image.alpha_composite(img.convert("RGBA"), glow)
    grid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    for y in range(0, H, 120):
        gd.line([(0, y), (W, y)], fill=(255, 255, 255, 8), width=1)
    for x in range(0, W, 120):
        gd.line([(x, 0), (x, H)], fill=(255, 255, 255, 5), width=1)
    return Image.alpha_composite(base, grid)


BG = None


def wrap(text, f, max_w):
    lines, cur = [], ""
    for ch in text:
        if f.getlength(cur + ch) <= max_w or not cur:
            cur += ch
        else:
            lines.append(cur)
            cur = ch
    if cur:
        lines.append(cur)
    if len(lines) > 1 and len(lines[-1]) <= 2:
        lines[-2] = lines[-2] + lines[-1]
        lines.pop()
    return lines


def text_block(d, xy, lines, f, fill, gap=1.18, stroke=0):
    x, y = xy
    lh = int(f.size * gap)
    for i, line in enumerate(lines):
        d.text((x, y + i * lh), line, font=f, fill=fill, stroke_width=stroke, stroke_fill=fill)
    return y + len(lines) * lh


def scene_common(img, d, idx, eyebrow, lt):
    a = ease_out(clamp(lt / 0.5))
    # 顶部品牌行
    d.line([(90, 150), (90 + int(150 * a), 150)], fill=ACCENT + (200,), width=3)
    d.text((90, 96), eyebrow, font=F["small"], fill=ACCENT)
    d.text((W - 90, 96), f"{idx:02d} / {len(SCENES):02d}", font=F["small"], fill=MUTED, anchor="ra")
    d.line([(90, 168), (W - 90, 168)], fill=(255, 255, 255, 18), width=1)


def fit_font(lines, max_w, start, index=0):
    size = start
    while size > 24 and max(font(size, index).getlength(l) for l in lines) > max_w:
        size -= 4
    return font(size, index)


def draw_headline(d, head, lt, y=520, f=None, size_gap=1.12):
    f = fit_font(head, W - 180, (f or F["h1"]).size)
    lh = int(f.size * size_gap)
    for i, line in enumerate(head):
        t = ease_out(clamp((lt - 0.12 - i * 0.09) / 0.55))
        if t <= 0:
            continue
        dy = int((1 - t) * 46)
        col = INK if i == 0 else ACCENT
        d.text((90, y + i * lh + dy), line, font=f, fill=col + (int(255 * t),), stroke_width=1, stroke_fill=col)
    return y + len(head) * lh


def draw_chips(d, chips, lt, y, max_w=900):
    x, cy = 90, y
    for i, c in enumerate(chips):
        t = ease_out(clamp((lt - 0.45 - i * 0.11) / 0.4))
        if t <= 0:
            continue
        f = F["chip"]
        w = int(f.getlength(c) + 52)
        if x + w > 90 + max_w:
            x, cy = 90, cy + 84
        alpha = int(255 * t)
        d.rounded_rectangle([x, cy + int((1 - t) * 16), x + w, cy + 68 + int((1 - t) * 16)],
                            radius=34, fill=(255, 255, 255, int(16 * t)), outline=ACCENT + (int(90 * t),), width=2)
        d.text((x + 26, cy + 12 + int((1 - t) * 16)), c, font=f, fill=INK + (alpha,))
        x += w + 16
    return cy + 68


def art_share(d, lt):
    t = ease_out(clamp((lt - 0.25) / 0.6))
    if t <= 0:
        return
    cx, cy = W / 2, 1320
    dy = int((1 - t) * 40)
    panel = [cx - 380, cy - 130 + dy, cx + 380, cy + 150 + dy]
    d.rounded_rectangle(panel, radius=44, fill=(255, 255, 255, int(34 * t)), outline=(255, 255, 255, int(64 * t)), width=2)
    d.text((cx - 340, cy - 96 + dy), "分享给", font=F["body"], fill=MUTED + (int(255 * t),))
    for i in range(5):
        p = ease_out(clamp((lt - 0.5 - i * 0.07) / 0.35))
        if p <= 0:
            continue
        x = cx - 300 + i * 150
        r = 46 * p
        d.ellipse([x - r, cy - 24 + dy - r, x + r, cy - 24 + dy + r], fill=(60, 92, 108, int(230 * p)))
        d.rounded_rectangle([x - 34, cy + 44 + dy, x + 34, cy + 58 + dy], radius=7, fill=(90, 120, 136, int(220 * p)))
    for i in range(4):
        p = ease_out(clamp((lt - 0.8 - i * 0.06) / 0.3))
        if p <= 0:
            continue
        x = cx - 225 + i * 150
        r = 34 * p
        d.ellipse([x - r, cy + 104 + dy - r, x + r, cy + 104 + dy + r], outline=ACCENT + (int(200 * p),), width=3)


def art_cache(d, lt):
    t = ease_out(clamp((lt - 0.25) / 0.6))
    if t <= 0:
        return
    cx, cy = W / 2, 1300
    for i in range(3):
        p = ease_out(clamp((lt - 0.3 - i * 0.12) / 0.5))
        if p <= 0:
            continue
        off = i * 26
        d.rounded_rectangle([cx - 330 + off, cy - 60 - off + int((1 - p) * 30), cx + 330 + off, cy + 90 - off + int((1 - p) * 30)],
                            radius=30, fill=(255, 255, 255, int((46 - i * 8) * p)), outline=(255, 255, 255, int(70 * p)), width=2)
    p = ease_out(clamp((lt - 0.9) / 0.5))
    if p > 0:
        x0, y0 = cx - 200, cy + 190
        d.line([(x0, y0), (x0 + 400 * p, y0)], fill=ACCENT + (220,), width=6)
        d.polygon([(x0 + 400 * p, y0 - 14), (x0 + 430 * p, y0), (x0 + 400 * p, y0 + 14)], fill=ACCENT + (220,))


def art_danmaku(d, lt):
    t = ease_out(clamp((lt - 0.25) / 0.6))
    if t <= 0:
        return
    x0, y0, x1, y1 = 140, 1180, W - 140, 1620
    d.rounded_rectangle([x0, y0, x1, y1], radius=26, fill=(255, 255, 255, int(24 * t)), outline=(255, 255, 255, int(48 * t)), width=2)
    third = y0 + (y1 - y0) / 3
    dash = 22
    x = x0 + 10
    while x < x1 - 10:
        d.line([(x, third), (min(x + 12, x1 - 10), third)], fill=ACCENT + (210,), width=3)
        x += dash
    d.text((x0 + 18, third + 12), "上三分之一", font=F["small"], fill=ACCENT + (200,))
    for i, (yy, speed, wpx) in enumerate([(1220, 260, 200), (1290, 330, 260), (1360, 210, 160), (1430, 300, 220)]):
        p = ease_out(clamp((lt - 0.5 - i * 0.1) / 1.4))
        if p <= 0:
            continue
        sx = x0 + 30 + (x1 - x0 - 60 - wpx) * p
        d.rounded_rectangle([sx, yy, sx + wpx, yy + 40], radius=20, fill=(255, 255, 255, int(70 * p)))


def art_grid(d, lt):
    t = ease_out(clamp((lt - 0.25) / 0.6))
    if t <= 0:
        return
    cols, rows = 4, 3
    cw, ch = 200, 96
    gx, gy = W / 2 - cols * cw / 2, 1200
    for r in range(rows):
        for c in range(cols):
            i = r * cols + c
            p = ease_out(clamp((lt - 0.3 - i * 0.05) / 0.4))
            if p <= 0:
                continue
            x, y = gx + c * cw, gy + r * ch
            on = i == 0
            d.rounded_rectangle([x + 8, y + 8, x + cw - 8, y + ch - 24], radius=22,
                                fill=(ACCENT + (int(70 * p),)) if on else (255, 255, 255, int(30 * p)),
                                outline=(ACCENT + (int(160 * p),)) if on else (255, 255, 255, int(34 * p)), width=2)


def art_rail(d, lt):
    t = ease_out(clamp((lt - 0.25) / 0.6))
    if t <= 0:
        return
    cx, cy = W / 2, 1250
    d.rounded_rectangle([cx - 60, cy - 90, cx + 60, cy + 330], radius=60, fill=(255, 255, 255, int(28 * t)),
                        outline=(255, 255, 255, int(56 * t)), width=2)
    for i in range(4):
        p = ease_out(clamp((lt - 0.45 - i * 0.1) / 0.4))
        if p <= 0:
            continue
        y = cy - 30 + i * 88
        r = 26 * p
        d.ellipse([cx - r, y - r, cx + r, y + r], outline=ACCENT + (int(230 * p),), width=4)
        d.rounded_rectangle([cx - 30, y + 34, cx + 30, y + 44], radius=5, fill=(120, 148, 162, int(220 * p)))


def art_menu(d, lt):
    t = ease_out(clamp((lt - 0.25) / 0.6))
    if t <= 0:
        return
    cx, cy = W / 2, 1300
    for i, (w, h) in enumerate([(620, 320), (460, 236), (300, 152)]):
        p = ease_out(clamp((lt - 0.3 - i * 0.13) / 0.5))
        if p <= 0:
            continue
        d.rounded_rectangle([cx - w / 2, cy - h / 2 + int((1 - p) * 24), cx + w / 2, cy + h / 2 + int((1 - p) * 24)],
                            radius=34, fill=(255, 255, 255, int((32 + i * 8) * p)), outline=(255, 255, 255, int(64 * p)), width=2)


def art_badges(d, lt):
    t = ease_out(clamp((lt - 0.25) / 0.6))
    if t <= 0:
        return
    cx, cy = W / 2, 1320
    labels = ["发布时间", "AI 声明", "发送回执"]
    for i, lab in enumerate(labels):
        p = ease_out(clamp((lt - 0.35 - i * 0.12) / 0.45))
        if p <= 0:
            continue
        w, h = 260, 80
        x = cx - w / 2
        y = cy - 160 + i * 110 + int((1 - p) * 20)
        d.rounded_rectangle([x, y, x + w, y + h], radius=40, fill=(255, 255, 255, int(32 * p)), outline=ACCENT + (int(170 * p),), width=2)
        d.text((cx, y + 16), lab, font=F["body"], fill=INK + (int(255 * p),), anchor="ma")


ART = {"share": art_share, "cache": art_cache, "danmaku": art_danmaku, "grid": art_grid,
       "rail": art_rail, "menu": art_menu, "badges": art_badges}


def draw_subtitle(d, text, alpha):
    if alpha <= 0:
        return
    f = F["sub"]
    lines = wrap(text, f, W - 260)
    if len(lines) > 3:
        lines = lines[:3]
    lh = int(f.size * 1.26)
    h = lh * len(lines) + 46
    box = [110, H - 150 - h, W - 110, H - 150]
    d.rounded_rectangle(box, radius=26, fill=(3, 8, 12, int(190 * alpha)))
    for i, line in enumerate(lines):
        d.text((W / 2, box[1] + 22 + i * lh), line, font=f, fill=INK + (int(255 * alpha),), anchor="ma")


def draw_timeline(d, lt):
    t = ease_out(clamp((lt - 0.35) / 0.9))
    y = 1180
    x0, x1 = 140, W - 140
    d.line([(x0, y), (x0 + int((x1 - x0) * t), y)], fill=(255, 255, 255, 40), width=3)
    vers = ["1.3.4", "1.3.5", "1.3.7", "1.3.8"]
    for i, v in enumerate(vers):
        p = ease_out(clamp((lt - 0.5 - i * 0.18) / 0.45))
        if p <= 0:
            continue
        x = x0 + (x1 - x0) * (i / (len(vers) - 1))
        last = i == len(vers) - 1
        r = (16 if last else 10) * p
        fill = (ACCENT[0], ACCENT[1], ACCENT[2], int(255 * p)) if last else (255, 255, 255, int(140 * p))
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)
        d.line([(x, y), (x, y - 46)], fill=(255, 255, 255, int(60 * p)), width=2)
        d.text((x, y - 96), v, font=F["lead"] if last else F["small"],
               fill=(ACCENT if last else MUTED) + (int(255 * p),), anchor="ma")
    p = ease_out(clamp((lt - 1.4) / 0.5))
    if p > 0:
        d.text((W / 2, y + 90), "四个版本 · 四十处改动", font=F["body"], fill=MUTED + (int(255 * p),), anchor="ma")


def draw_download(d, lt):
    cy = 900
    for i, (label, url, tail) in enumerate(LINKS):
        p = ease_out(clamp((lt - 0.3 - i * 0.2) / 0.55))
        if p <= 0:
            continue
        y = cy + i * 330 + int((1 - p) * 30)
        d.rounded_rectangle([90, y, W - 90, y + 250], radius=36, fill=(255, 255, 255, int(26 * p)),
                            outline=(ACCENT if i == 0 else WARM) + (int(120 * p),), width=3)
        d.text((130, y + 30), label, font=F["chip"], fill=(ACCENT if i == 0 else WARM) + (int(255 * p),))
        d.text((130, y + 92), url, font=F["body"], fill=INK + (int(255 * p),))
        d.text((130, y + 158), tail, font=F["mono"], fill=MUTED + (int(255 * p),))


def render_scene(img, d, sc, idx, lt, dur, sub):
    scene_common(img, d, idx, sc["eyebrow"], lt)
    if sc["kind"] == "title":
        draw_headline(d, sc["head"], lt, y=640, f=F["hero"], size_gap=1.04)
        p = ease_out(clamp((lt - 0.8) / 0.5))
        if p > 0:
            d.text((96, 1120), "抖音第三方客户端 · 新版本发布", font=F["sub"], fill=MUTED + (int(255 * p),))
        p = ease_out(clamp((lt - 1.05) / 0.5))
        if p > 0:
            d.line([(96, 1210), (96 + 420 * p, 1210)], fill=ACCENT + (200,), width=4)
    elif sc["kind"] == "timeline":
        draw_headline(d, sc["head"], lt, y=600)
        draw_timeline(d, lt)
    elif sc["kind"] == "download":
        draw_headline(d, sc["head"], lt, y=560)
        draw_download(d, lt)
    elif sc["kind"] == "end":
        draw_headline(d, sc["head"], lt, y=760, f=F["h2"])
        p = ease_out(clamp((lt - 0.6) / 0.5))
        if p > 0:
            d.text((W / 2, 1010), "未签名 IPA · 自己签名安装", font=F["lead"], fill=MUTED + (int(255 * p),), anchor="ma")
        p = ease_out(clamp((lt - 0.85) / 0.5))
        if p > 0:
            d.text((W / 2, 1100), "iOS / iPadOS 17.0 及以上", font=F["body"], fill=ACCENT + (int(255 * p),), anchor="ma")
        p = ease_out(clamp((lt - 1.2) / 0.5))
        if p > 0:
            d.text((W / 2, 1560), "非官方客户端 · 仅供个人学习交流", font=F["small"], fill=MUTED + (int(150 * p),), anchor="ma")
    else:
        y = draw_headline(d, sc["head"], lt, y=520)
        draw_chips(d, sc["chips"], lt, y + 46)
        ART[sc["art"]](d, lt)
    draw_subtitle(d, sub, ease_out(clamp((lt - 0.15) / 0.35)))


def synth():
    AUDIO.mkdir(exist_ok=True)
    meta = []
    for i, sc in enumerate(SCENES):
        out = AUDIO / f"s{i:02d}.wav"
        aiff = AUDIO / f"s{i:02d}.aiff"
        subprocess.run(["say", "-v", VOICE, "-r", str(RATE), "-o", str(aiff), sc["say"]], check=True)
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(aiff), "-ar", "44100", "-ac", "1",
                        "-c:a", "pcm_s16le", str(out)], check=True)
        with wave.open(str(out)) as w:
            dur = w.getnframes() / w.getframerate()
        meta.append({"index": i, "audio": str(out), "audio_dur": dur,
                     "dur": round(LEAD_IN + dur + TAIL, 3)})
    return meta


def build_audio(meta, total):
    pcm = bytearray()
    for m in meta:
        with wave.open(m["audio"]) as w:
            frames = w.readframes(w.getnframes())
        pcm += b"\x00\x00" * int(44100 * LEAD_IN)
        pcm += frames
        pad = m["dur"] - LEAD_IN - m["audio_dur"]
        pcm += b"\x00\x00" * int(44100 * pad)
    path = ROOT / "narration.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(bytes(pcm))
    return path


def main():
    global BG
    meta = synth()
    (ROOT / "scenes.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    BG = gradient_bg()
    if FRAMES.exists():
        shutil.rmtree(FRAMES)
    FRAMES.mkdir()
    total = sum(m["dur"] for m in meta)
    done = 0
    for m in meta:
        sc = SCENES[m["index"]]
        n = int(round(m["dur"] * FPS))
        for k in range(n):
            lt = k / FPS
            layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            render_scene(layer, d, sc, m["index"] + 1, lt, m["dur"], sc["say"])
            img = Image.alpha_composite(BG, layer)
            img.convert("RGB").save(FRAMES / f"{done:05d}.png", compress_level=1)
            done += 1
        print(f"scene {m['index'] + 1}/{len(SCENES)} {m['dur']:.2f}s", flush=True)
    audio = build_audio(meta, total)
    out = ROOT / "douduo-1.3.8-release.mp4"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-framerate", str(FPS), "-i", str(FRAMES / "%05d.png"),
                    "-i", str(audio), "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "medium",
                    "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
                    "-movflags", "+faststart", "-shortest", str(out)], check=True)
    print(json.dumps({"video": str(out), "duration": round(done / FPS, 2), "frames": done}, ensure_ascii=False))


if __name__ == "__main__":
    main()

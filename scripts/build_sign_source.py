#!/usr/bin/env python3
"""生成全能签 / 轻松签等签名工具可用的 DouDuo 软件源（两份）。

  docs/source/douduo.json         国内源：源文件和安装包都走 Gitee
  docs/source/douduo-github.json  海外源：源文件和安装包都走 GitHub

数据全部来自 GitHub 正式 Release（版本号、发布时间、发行说明、IPA 大小），
默认收录最近 5 个带 unsigned.ipa 的版本，新的在前。Gitee 缺某个版本时，国内源该版本
下载地址自动回落到 GitHub 并打印提示（先跑 scripts/sync_gitee_release.py 补齐）。

每次发版后：
  python3 scripts/sync_gitee_release.py      # Gitee 补发行版 + IPA
  python3 scripts/build_sign_source.py       # 重新生成两份源
  git add docs/source && git commit && git push origin main && git push gitee main
"""
import argparse, json, pathlib, re, subprocess, sys, urllib.request

GH_REPO = "81199000/DouDuo"
GITEE_REPO = "remon8/douduo"
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "docs/source"
GITEE_RAW = f"https://gitee.com/{GITEE_REPO}/raw/main"
GH_RAW = f"https://raw.githubusercontent.com/{GH_REPO}/main"
BUNDLE_ID = "me.rrmm.douduo"
SUBTITLE = "原生 SwiftUI 第三方抖音客户端，适配折叠屏与 iPad"
DESC = ("DouDuo：开源免费的第三方抖音客户端（非官方），原生 SwiftUI，适配 iPhone Duo 折叠屏、iPad 与普通 iPhone。"
        "安装包为未签名 IPA，需要用自己的证书签名。仅供个人学习交流。")


def gh_releases(limit):
    out = subprocess.run(["gh", "api", f"repos/{GH_REPO}/releases?per_page=30"],
                         capture_output=True, text=True, check=True).stdout
    rels = []
    for r in json.loads(out):
        if r.get("draft") or r.get("prerelease"):
            continue
        ipa = next((a for a in r["assets"] if a["name"].endswith("-unsigned.ipa")), None)
        if ipa:
            rels.append((r, ipa))
    return rels[:limit]


def gitee_assets():
    """{tag: {附件名}}：Gitee 已经挂好的版本。"""
    try:
        with urllib.request.urlopen(f"https://gitee.com/api/v5/repos/{GITEE_REPO}/releases?per_page=100", timeout=20) as r:
            return {x["tag_name"]: {a.get("name") for a in x.get("assets", [])} for x in json.load(r)}
    except Exception as e:
        print(f"⚠️ 读取 Gitee 发行版失败：{e}", file=sys.stderr)
        return {}


def plain_notes(md, limit=800):
    """发行说明转纯文本（签名工具里按纯文本展示），控制长度。"""
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", md or "")
    t = re.sub(r"[*`]", "", t)
    t = re.sub(r"^#+\s*", "", t, flags=re.M)
    t = re.sub(r"<[^>]+>", "", t)
    t = re.sub(r"\n{3,}", "\n\n", t).strip()
    return t if len(t) <= limit else t[:limit].rsplit("\n", 1)[0] + "\n…完整说明见发行版页面"


def build(kind, rels, gitee):
    raw = GITEE_RAW if kind == "gitee" else GH_RAW
    icon = f"{raw}/docs/brand/app-icon.png"
    apps, fallback = [], []
    for r, ipa in rels:
        tag = r["tag_name"]
        url = ipa["browser_download_url"]
        if kind == "gitee":
            if ipa["name"] in gitee.get(tag, set()):
                url = f"https://gitee.com/{GITEE_REPO}/releases/download/{tag}/{ipa['name']}"
            else:
                fallback.append(tag)
        apps.append({
            "name": "DouDuo",
            "bundleIdentifier": BUNDLE_ID,
            "type": "1",
            "version": tag.lstrip("v"),
            "versionDate": r["published_at"].replace("Z", "+00:00"),
            "versionDescription": plain_notes(r.get("body") or r.get("name") or tag),
            "subtitle": SUBTITLE,
            "localizedDescription": DESC,
            "lock": "0",
            "downloadURL": url,
            "isLanZouCloud": "0",
            "iconURL": icon,
            "tintColor": "FE2C55",
            "size": str(ipa["size"]),
        })
    file = "douduo.json" if kind == "gitee" else "douduo-github.json"
    src = {
        "name": "DouDuo 官方源" + ("（国内）" if kind == "gitee" else "（GitHub）"),
        "identifier": "me.rrmm.douduo.source" + ("" if kind == "gitee" else ".github"),
        "sourceURL": f"{raw}/docs/source/{file}",
        "sourceicon": icon,
        "message": "DouDuo 官方软件源。安装包均来自官方仓库发行版（未签名），需要自备证书签名。\n"
                   "开源免费，非抖音官方，仅供个人学习交流。",
        "payURL": "",
        "unlockURL": "",
        "apps": apps,
    }
    (OUT_DIR / file).write_text(json.dumps(src, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return file, fallback


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", type=int, default=5, help="收录最近几个版本（默认 5）")
    args = ap.parse_args()
    rels = gh_releases(args.keep)
    if not rels:
        sys.exit("GitHub 没有带 unsigned.ipa 的正式版")
    gitee = gitee_assets()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for kind in ("gitee", "github"):
        file, fb = build(kind, rels, gitee)
        print(f"✅ docs/source/{file}  {', '.join(r['tag_name'] for r, _ in rels)}")
        if fb:
            print(f"   ⚠️ Gitee 缺 {', '.join(fb)}，这些版本暂用 GitHub 下载；先跑 scripts/sync_gitee_release.py", file=sys.stderr)


if __name__ == "__main__":
    main()

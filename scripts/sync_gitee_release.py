#!/usr/bin/env python3
"""把 GitHub 上某个正式 Release（默认最新）同步到 Gitee 发行版：建发行版 + 上传 unsigned.ipa。

前置：tag 已推到 gitee（git push gitee main && git push gitee vX.Y.Z）。
凭据：~/.hermes/shared-credentials/gitee-remon8.json 的 access_token（不入库）。
用法：python3 scripts/sync_gitee_release.py [vX.Y.Z]
幂等：发行版已存在 / IPA 已挂上就跳过；最后匿名下载核对大小。
"""
import json, pathlib, subprocess, sys, tempfile, urllib.error, urllib.request, uuid

GH = "81199000/DouDuo"
API = "https://gitee.com/api/v5/repos/remon8/douduo"
TOK = json.loads((pathlib.Path.home() / ".hermes/shared-credentials/gitee-remon8.json").read_text())["access_token"]


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


def call(method, url, data=None, headers=None, timeout=60):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": "token " + TOK, **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else json.loads(gh("api", f"repos/{GH}/releases/latest"))["tag_name"]
    rel_gh = json.loads(gh("api", f"repos/{GH}/releases/tags/{tag}"))
    ipa = next(a for a in rel_gh["assets"] if a["name"].endswith("-unsigned.ipa"))

    try:
        rel = call("GET", f"{API}/releases/tags/{tag}")
        rel = rel if rel and rel.get("id") else None
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        rel = None
    if not rel:
        body = json.dumps({"tag_name": tag, "target_commitish": tag, "name": rel_gh["name"],
                           "body": rel_gh.get("body") or tag, "prerelease": False}).encode()
        rel = call("POST", f"{API}/releases", body, {"Content-Type": "application/json"})
        print("发行版已创建", rel["id"])
    else:
        print("发行版已存在", rel["id"])

    if ipa["name"] not in [a.get("name") for a in rel.get("assets", [])]:
        # 本机刚打好的包和 GitHub 上那份大小一致就直接用，省一次下载（家里网络从 GitHub 拉大文件常中途断）
        # 只用本机刚打好的包上传；不再从 GitHub 下载回来再传（老板 11-21：上传完不该再下载再上传）
        local = pathlib.Path(__file__).resolve().parent.parent / "build" / ipa["name"]
        if not (local.exists() and local.stat().st_size == ipa["size"]):
            sys.exit(f"本机没有 {local}（或大小 ≠ GitHub 上的 {ipa['size']}），请在打包的这台机器上跑")
        data = local.read_bytes()
        b = uuid.uuid4().hex
        payload = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{ipa['name']}\"\r\n"
                   f"Content-Type: application/octet-stream\r\n\r\n").encode() + data + f"\r\n--{b}--\r\n".encode()
        call("POST", f"{API}/releases/{rel['id']}/attach_files", payload,
             {"Content-Type": f"multipart/form-data; boundary={b}"}, timeout=900)
        print("IPA 已上传", len(data))
    else:
        print("IPA 已挂上")

    # 只看响应头里的大小，不下载整包（以前把 22MB 完整下一遍来核对）
    url = f"https://gitee.com/remon8/douduo/releases/download/{tag}/{ipa['name']}"
    out = subprocess.run(["curl", "-sIL", "-m", "60", "-o", "/dev/null", "-w", "%{http_code} %header{content-length}", url],
                         capture_output=True, text=True).stdout.split()
    ok = len(out) == 2 and out[0] == "200" and out[1].isdigit() and int(out[1]) == ipa["size"]
    print(("✅" if ok else "❌"), "匿名地址核对（只读大小）", out, "期望大小", ipa["size"])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import re
import subprocess
import sys

PATTERN = re.compile(
    r"老板|小号|大号|主人|升爷|豹子|机暴|蓝暴|白虎|机龙|红暴|"
    r"\b(jibao|baozi|lanbao|baihu|jilong|redbao|shayu|wuli)\b|DouDuo [NR]\b|"
    r"無為-Duo|00008160-|zhanghongsheng|/Users/[a-z]|張宏升|张宏升|广东日明"
)
SKIP = (".jpg", ".png", ".svg", ".ico", ".pbxproj")


def staged():
    out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
                         capture_output=True, text=True, check=True).stdout.split()
    return [f for f in out if not f.endswith(SKIP) and f != "scripts/check_private_words.py"]


def tracked():
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    return [f for f in out if not f.endswith(SKIP) and f != "scripts/check_private_words.py"]


def main():
    files = tracked() if "--all" in sys.argv else staged()
    hits = []
    for f in files:
        try:
            text = subprocess.run(["git", "show", ":" + f] if "--all" not in sys.argv else ["cat", f],
                                  capture_output=True, text=True).stdout
        except Exception:
            continue
        for i, line in enumerate(text.split("\n"), 1):
            if PATTERN.search(line):
                hits.append(f"{f}:{i}: {line.strip()[:120]}")
    if hits:
        print("提交里有内部称呼 / 设备号 / 本机路径，先删掉再提交：")
        print("\n".join(hits))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

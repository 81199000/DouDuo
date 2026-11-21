#!/bin/zsh
# DouDuo 一键发版（给 AI / 自动化直接跑；人也一样用）
#
#   scripts/release.sh                 # 版本号自动 = 最新 tag 的末位 +1
#   scripts/release.sh 1.7.0           # 指定版本号
#   scripts/release.sh --dry-run       # 只演练（编译 + 打包 + 测试），不提交不发
#
# 会做的事：同步 main → 没有发行说明就按上次发版以来的提交自动生成 → scripts/publish.sh
# （编译/测试 → tag → GitHub + Gitee 发行版 → 软件源 → dl.oneduo.app → 装 Duo → 验收）。
# 中途失败直接重跑本脚本即可：已完成的步骤会跳过。
# 只能在主干 ~/Projects/douduo 跑；同一时间只允许一个发版（加锁）。
# 不传 TestFlight（老板 11-20 要求）；不装手机用 DOUDUO_INSTALL=0。
# 结束时最后一行固定格式：RELEASE_RESULT ok|fail version=X.Y.Z build=N
set -uo pipefail
cd "$(dirname "$0")/.."
LOG=${TMPDIR:-/tmp}/douduo-release-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

DRY=""; VER=""
for a in "$@"; do case $a in --dry-run) DRY=--dry-run ;; *) VER=$a ;; esac; done
fail() { print -P "%F{red}❌ $1%f"; print "日志：$LOG"; print "RELEASE_RESULT fail version=${VER:-?} reason=${2:-error}"; exit 1; }

# ---------- 锁 ----------
LOCK=${TMPDIR:-/tmp}/douduo-release.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null)
  if [[ -n $pid ]] && kill -0 $pid 2>/dev/null; then fail "已有发版在跑（pid $pid）" locked; fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
print $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# ---------- 同步 main ----------
[[ $(git branch --show-current) == main ]] || fail "只能在 main 上发（当前 $(git branch --show-current)）" branch
[[ -z $(git status --porcelain --untracked-files=no) ]] || fail "主干有未提交改动：$(git status --porcelain --untracked-files=no | head -3 | tr '\n' ' ')" dirty
git fetch -q origin --tags || fail "git fetch 失败" network
git merge -q --ff-only origin/main || fail "本地 main 和 origin/main 分叉了，先人工处理" diverged

# ---------- 版本号 ----------
LAST=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)
if [[ -z $VER ]]; then
  # 上一个 tag 发了一半（还没发行说明以外的东西）就续发同一个版本
  if [[ -n $LAST ]] && ! gh release view $LAST >/dev/null 2>&1; then VER=${LAST#v}
  else
    b=${LAST#v}; VER=${b%.*}.$(( ${b##*.} + 1 ))
  fi
fi
[[ $VER =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "版本号格式不对：$VER" version
TAG=v$VER
print "▶ 发版 DouDuo $VER（上一版 $LAST）"

# ---------- 发行说明 ----------
NOTES=docs/releases/$TAG.md
if [[ ! -f $NOTES ]]; then
  BASE=$LAST; [[ $BASE == $TAG ]] && BASE=$(git tag --list 'v[0-9]*' --sort=-v:refname | sed -n 2p)
  python3 - "$VER" "$BASE" "$NOTES" <<'PY' || fail "生成发行说明失败" notes
import re, subprocess, sys
ver, base, out = sys.argv[1:]
subjects = subprocess.run(["git", "log", "--format=%s", f"{base}..HEAD"], capture_output=True, text=True).stdout.splitlines()
feat, fix = [], []
for s in subjects:
    m = re.match(r"(feat|fix)(?:\(([^)]*)\))?:\s*(.+)", s)
    if not m or m.group(2) in ("发版", "源", "诊断", "tf"):
        continue
    text = re.split(r"[——;；]", m.group(3))[0].strip()      # 只取破折号前的一句话
    (feat if m.group(1) == "feat" else fix).append(f"- {m.group(2) + '：' if m.group(2) else ''}{text}")
lines = [f"# DouDuo {ver}", "", "包为**未签名 IPA**，需要自行签名安装。", ""]
if feat: lines += ["## 新功能", *dict.fromkeys(feat), ""]
if fix:  lines += ["## 修复", *dict.fromkeys(fix), ""]
if not feat and not fix:
    lines += ["## 说明", "这一版 App 功能与上一版相同，主要是发布流程与内部改进。", ""]
lines += ["## 关注不走失",
          "项目在 GitHub [81199000/DouDuo](https://github.com/81199000/DouDuo)，点个 Star、关注 @81199000，避免走失。"
          "官网 [oneduo.app](https://oneduo.app) 是长期固定入口。", ""]
open(out, "w").write("\n".join(lines))
print(f"发行说明自动生成：{out}（{len(feat)} 新功能 / {len(fix)} 修复）")
PY
  if [[ -z $DRY ]]; then
    git add $NOTES && git commit -q -m "docs(发版): $VER 发行说明（自动生成）" && git push -q origin main \
      || fail "提交发行说明失败" notes
    git push -q gitee main 2>&1 | grep -v 'GITEE\|trace'
  fi
fi

# ---------- 发 ----------
zsh scripts/publish.sh $VER $DRY
rc=$?
[[ -n $DRY ]] && { git checkout -q -- $NOTES 2>/dev/null; git ls-files --error-unmatch $NOTES >/dev/null 2>&1 || rm -f $NOTES; }
(( rc == 0 )) || fail "publish.sh 失败（退出码 $rc），修好后重跑 scripts/release.sh $VER" publish
BUILD=$(sed -nE 's/^ +CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' project.yml | head -1)
print "日志：$LOG"
print "RELEASE_RESULT ok version=$VER build=$BUILD${DRY:+ dry-run}"

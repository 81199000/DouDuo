#!/bin/zsh
# DouDuo 一键发版：GitHub + Gitee 同步发行版，并更新全能签 / 轻松签软件源。
#
# 用法（只能在主干 ~/Projects/douduo 的 main 上跑）：
#   scripts/publish.sh 1.6.0            # 版本号；构建号自动 +1
#   scripts/publish.sh 1.6.0 --dry-run  # 只做检查 + 编译 + 测试，不打 tag、不推、不发
#
# 前置：docs/releases/v<版本>.md 已写好；gh 已登录；Gitee token 在
#       ~/.hermes/shared-credentials/gitee-remon8.json（不入库）；Vendor/VLCKit 已就位。
# 步骤：检查 → 改版本号 → 编译(模拟器+未签名真机包) → 全部脚本测试 → 提交 → tag →
#       推 GitHub/Gitee → GitHub Release → Gitee 发行版 → 软件源 → 推送 → 匿名验收。
# 任何一步失败立即停止；重跑是安全的（已发的 Release / Gitee 发行版 / 软件源都会跳过或覆盖）。
set -euo pipefail
cd "$(dirname "$0")/.."

VER=${1:?用法：scripts/publish.sh <版本号> [--dry-run]}
DRY=${2:-}
TAG=v$VER
NOTES=docs/releases/$TAG.md
IPA=build/DouDuo-$VER-unsigned.ipa
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148'
step() { print -P "\n%F{cyan}▶ $1%f"; }
die()  { print -P "%F{red}❌ $1%f" >&2; exit 1; }

# ---------- 1. 检查 ----------
step "检查环境"
[[ $VER =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "版本号格式应为 X.Y.Z：$VER"
[[ $(git branch --show-current) == main ]] || die "只能在 main 上发版（当前 $(git branch --show-current)）"
[[ -z $(git status --porcelain --untracked-files=no) ]] || die "工作区有未提交改动"
[[ -f $NOTES ]] || die "缺发行说明 $NOTES"
[[ -d Vendor/VLCKit/VLCKit-all.xcframework ]] || die "缺 Vendor/VLCKit（./scripts/fetch-vlckit.sh 或从主干克隆）"
[[ -f ~/.hermes/shared-credentials/gitee-remon8.json ]] || die "缺 Gitee token"
gh auth status >/dev/null 2>&1 || die "gh 未登录"
for c in xcodegen xcodebuild node python3; do command -v $c >/dev/null || die "缺 $c"; done
git fetch -q origin --tags; git fetch -q gitee
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "本地 main 与 origin/main 不一致，先同步"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ $(git rev-list -n1 $TAG) == $(git rev-parse HEAD) ]] || die "$TAG 已存在且不在当前 HEAD"
  RESUME=1; print "↻ $TAG 已在 HEAD，继续未完成的发布步骤"
else
  RESUME=0
fi

# ---------- 2. 版本号 ----------
if (( ! RESUME )); then
  step "版本号 → $VER"
  OLD_BUILD=$(sed -nE 's/^ +CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' project.yml | head -1)
  BUILD=$((OLD_BUILD + 1))
  sed -i '' -E "s/^( +MARKETING_VERSION: ).*/\1$VER/; s/^( +CURRENT_PROJECT_VERSION: ).*/\1\"$BUILD\"/" project.yml
  xcodegen generate >/dev/null
  print "MARKETING_VERSION=$VER  CURRENT_PROJECT_VERSION=$BUILD"
fi

# ---------- 3. 编译 ----------
step "模拟器编译"
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$TMPDIR/dd-publish-sim" \
  build CODE_SIGNING_ALLOWED=NO > "$TMPDIR/dd-publish-sim.log" 2>&1 \
  || { grep -E 'error:' "$TMPDIR/dd-publish-sim.log" | head; die "模拟器编译失败（$TMPDIR/dd-publish-sim.log）"; }

step "真机未签名包"
DD=$TMPDIR/dd-publish-rel
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO > "$TMPDIR/dd-publish-rel.log" 2>&1 \
  || { grep -E 'error:' "$TMPDIR/dd-publish-rel.log" | head; die "真机编译失败（$TMPDIR/dd-publish-rel.log）"; }
APP=$DD/Build/Products/Release-iphoneos/DouDuo.app
GOT=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist")
[[ $GOT == $VER ]] || die "包内版本 $GOT ≠ $VER"
rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R "$APP" build/ipa/Payload/
(cd build/ipa && rm -f "../${IPA:t}" && zip -qry "../${IPA:t}" Payload)
SIZE=$(stat -f %z $IPA)
print "✅ $IPA  $SIZE 字节  build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist")"

# ---------- 4. 测试 ----------
step "脚本测试"
fails=()
for t in scripts/test_*.py scripts/test_*.js; do
  case $t in *.py) python3 $t >/dev/null 2>&1 ;; *.js) node $t >/dev/null 2>&1 ;; esac || fails+=$t
done
(( ${#fails} == 0 )) || die "测试失败：${fails[*]}"
print "✅ 全部 $(ls scripts/test_*.py scripts/test_*.js | wc -l | tr -d ' ') 个通过"

if [[ $DRY == --dry-run ]]; then
  (( RESUME )) || git checkout -q -- project.yml DouDuo.xcodeproj/project.pbxproj
  print -P "\n%F{green}✅ dry-run 通过：编译、打包、测试均 OK（已还原版本号，未提交、未推送）%f"; exit 0
fi

# ---------- 5. 提交 + tag + 推送 ----------
if (( ! RESUME )); then
  step "提交并打 tag"
  git add project.yml DouDuo.xcodeproj/project.pbxproj
  git commit -q -m "release: DouDuo $VER（$BUILD）"
  git tag $TAG
fi
step "推送 GitHub / Gitee"
git push -q origin main; git push -q origin $TAG
git push -q gitee main 2>&1 | grep -v 'GITEE\|trace' || true
git push -q gitee $TAG 2>&1 | grep -v 'GITEE\|trace' || true

# ---------- 6. GitHub Release ----------
step "GitHub Release"
TITLE=$(head -1 $NOTES | sed 's/^# *//')
if gh release view $TAG >/dev/null 2>&1; then
  gh release edit $TAG --title "$TITLE" --notes-file $NOTES >/dev/null
else
  gh release create $TAG --title "$TITLE" --notes-file $NOTES --target main >/dev/null
fi
GH_SIZE=$(gh release view $TAG --json assets -q ".assets[]|select(.name==\"${IPA:t}\").size")
if [[ -n $GH_SIZE ]]; then
  # 已发过的包不覆盖：重新编译的 zip 字节会变，覆盖后 Gitee / 软件源里的大小就对不上了
  print "IPA 已在 GitHub（$GH_SIZE 字节），不覆盖"; SIZE=$GH_SIZE
else
  for i in 1 2 3; do gh release upload $TAG $IPA && break; print "上传重试 $i"; sleep 5; done
  GH_SIZE=$(gh release view $TAG --json assets -q ".assets[]|select(.name==\"${IPA:t}\").size")
  [[ $GH_SIZE == $SIZE ]] || die "GitHub 上的 IPA 大小 $GH_SIZE ≠ 本地 $SIZE"
fi

# ---------- 7. Gitee 发行版 ----------
step "Gitee 发行版"
python3 scripts/sync_gitee_release.py $TAG

# ---------- 8. 软件源 ----------
step "全能签 / 轻松签软件源"
python3 scripts/build_sign_source.py
if [[ -n $(git status --porcelain docs/source) ]]; then
  git add docs/source && git commit -q -m "chore(源): 软件源更新到 $TAG"
  git push -q origin main
  git push -q gitee main 2>&1 | grep -v 'GITEE\|trace' || true
fi

# ---------- 9. 匿名验收（手机 UA） ----------
step "验收"
ok=1
check_src() {  # $1 源地址  $2 期望下载域名
  local f=$TMPDIR/dd-publish-src.json code
  code=$(curl -sL -A "$UA" -H 'Cache-Control: no-cache' -o $f -w '%{http_code}' "$1?t=$(date +%s)")
  python3 - "$f" "$VER" "$2" "$code" <<'PY' || ok=0
import json, sys
f, ver, host, code = sys.argv[1:]
a = json.load(open(f))["apps"][0]
good = code == "200" and a["version"] == ver and f"//{host}/" in a["downloadURL"]
print(("✅" if good else "❌"), code, a["version"], a["downloadURL"])
sys.exit(0 if good else 1)
PY
}
check_src https://gitee.com/remon8/douduo/raw/main/docs/source/douduo.json gitee.com
check_src https://raw.githubusercontent.com/81199000/DouDuo/main/docs/source/douduo-github.json github.com
GITEE=$(curl -sL -A "$UA" -o /dev/null -w '%{http_code} %{size_download}' https://gitee.com/remon8/douduo/releases/download/$TAG/${IPA:t})
[[ $GITEE == "200 $SIZE" ]] && print "✅ Gitee IPA $GITEE" || { print "❌ Gitee IPA $GITEE"; ok=0; }
GHDL=$(curl -sL -A "$UA" -r 0-1023 -o /dev/null -w '%{http_code}' https://github.com/81199000/DouDuo/releases/download/$TAG/${IPA:t})
[[ $GHDL == 20[06] ]] && print "✅ GitHub IPA $GHDL" || { print "❌ GitHub IPA $GHDL"; ok=0; }
LATEST=$(curl -sI -A DouDuo-iOS https://github.com/81199000/DouDuo/releases/latest | sed -nE 's#^[Ll]ocation: .*/tag/([^[:space:]]+).*#\1#p')
[[ $LATEST == $TAG ]] && print "✅ App 内更新检查指向 $LATEST" || { print "❌ releases/latest → $LATEST"; ok=0; }
(( ok )) || die "验收未全部通过（raw 文件 CDN 有几分钟缓存，可稍后重跑本脚本）"

print -P "\n%F{green}✅ DouDuo $VER 发版完成%f
  GitHub  https://github.com/81199000/DouDuo/releases/tag/$TAG
  Gitee   https://gitee.com/remon8/douduo/releases/tag/$TAG
  软件源  国内 https://gitee.com/remon8/douduo/raw/main/docs/source/douduo.json
          海外 https://raw.githubusercontent.com/81199000/DouDuo/main/docs/source/douduo-github.json"

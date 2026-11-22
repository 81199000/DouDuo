#!/bin/zsh
# 发版时顺手装维护者自己的测试机：打签名包 → 本机或远程 Mac（哪台连着手机用哪台）装 → 更新本机局域网安装页（可选）。
# publish.sh 在后台调用；也可以单独跑：scripts/install_duo.sh
# 个人配置全部从环境变量或 ~/.config/douduo/local.env（不入库）读取：
#   DOUDUO_TEAM=签名团队ID  DOUDUO_DUO_UDID=测试机UDID  DOUDUO_MINI=用户@远程Mac（可选）  DOUDUO_SITE_DIR=局域网安装页目录（可选）
set -uo pipefail
cd "$(dirname "$0")/.."
LOCAL_ENV=${DOUDUO_LOCAL_ENV:-$HOME/.config/douduo/local.env}
[[ -f $LOCAL_ENV ]] && source "$LOCAL_ENV"
TEAM=${DOUDUO_TEAM:-}
UDID=${DOUDUO_DUO_UDID:-}
MINI=${DOUDUO_MINI:-}
SITE=${DOUDUO_SITE_DIR:-}
[[ -n $TEAM && -n $UDID ]] || { echo "未配置 DOUDUO_TEAM / DOUDUO_DUO_UDID（$LOCAL_ENV），跳过装机"; exit 0; }
OUT=build/adhoc; ARCH=build/DouDuo.xcarchive
rm -rf $ARCH $OUT
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -configuration Release -destination 'generic/platform=iOS' \
  -archivePath $ARCH -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM archive -quiet > "$TMPDIR/dd-install-archive.log" 2>&1 \
  && xcodebuild -exportArchive -archivePath $ARCH -exportPath $OUT -exportOptionsPlist signing/ExportOptions-adhoc.plist \
       -allowProvisioningUpdates -quiet >> "$TMPDIR/dd-install-archive.log" 2>&1 \
  || { echo "签名包失败（$TMPDIR/dd-install-archive.log）"; exit 1; }
IPA=$OUT/DouDuo.ipa
VER=$(unzip -p $IPA Payload/DouDuo.app/Info.plist | plutil -extract CFBundleShortVersionString raw -)

# 本机局域网安装页（可选，DOUDUO_SITE_DIR）
SEC=$([[ -n $SITE ]] && cat "$SITE/.dl_secret" 2>/dev/null)
if [[ -n $SEC && -d $SITE/dl/$SEC ]]; then
  cp $IPA "$SITE/dl/$SEC/DouDuo.ipa"
  /usr/libexec/PlistBuddy -c "Set :items:0:metadata:bundle-version $VER" "$SITE/dl/$SEC/douduo_manifest.plist" 2>/dev/null
  sed -i '' -E "s/1\.[0-9]+\.[0-9]+/$VER/g" "$SITE/douduo.html"
fi

installed() { grep -q 'App installed' <<<"$1"; }
r=$(xcrun devicectl device install app --device $UDID $IPA 2>&1)
if installed "$r"; then echo "✅ Duo 已装 $VER（本机）"; exit 0; fi
if [[ -n $MINI ]] && scp -q -o ConnectTimeout=8 $IPA $MINI:/tmp/DouDuo-publish.ipa 2>/dev/null; then
  r=$(ssh -o ConnectTimeout=8 $MINI "xcrun devicectl device install app --device $UDID /tmp/DouDuo-publish.ipa 2>&1")
  if installed "$r"; then echo "✅ Duo 已装 $VER（远程 Mac）"; exit 0; fi
fi
echo "测试机本机和远程 Mac 都连不上，没装；局域网安装页已更新到 $VER"; exit 1

#!/bin/zsh
# 发版时顺手装老板的 Duo：打签名包 → 本机或 Mac mini（哪台连着手机用哪台）装 → 更新本机局域网安装页。
# publish.sh 在后台调用；也可以单独跑：scripts/install_duo.sh
set -uo pipefail
cd "$(dirname "$0")/.."
UDID=${DOUDUO_DUO_UDID:-00008160-001924AE0E08000A}
MINI=${DOUDUO_MINI:-zhanghongsheng@192.168.30.100}
OUT=build/adhoc; ARCH=build/DouDuo.xcarchive
rm -rf $ARCH $OUT
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -configuration Release -destination 'generic/platform=iOS' \
  -archivePath $ARCH -allowProvisioningUpdates DEVELOPMENT_TEAM=${DOUDUO_TEAM:-FHMNKZL248} archive -quiet > "$TMPDIR/dd-install-archive.log" 2>&1 \
  && xcodebuild -exportArchive -archivePath $ARCH -exportPath $OUT -exportOptionsPlist signing/ExportOptions-adhoc.plist \
       -allowProvisioningUpdates -quiet >> "$TMPDIR/dd-install-archive.log" 2>&1 \
  || { echo "签名包失败（$TMPDIR/dd-install-archive.log）"; exit 1; }
IPA=$OUT/DouDuo.ipa
VER=$(unzip -p $IPA Payload/DouDuo.app/Info.plist | plutil -extract CFBundleShortVersionString raw -)

# 本机局域网安装页（~/Sites/wuwei）
SEC=$(cat ~/Sites/wuwei/.dl_secret 2>/dev/null)
if [[ -n $SEC && -d ~/Sites/wuwei/dl/$SEC ]]; then
  cp $IPA ~/Sites/wuwei/dl/$SEC/DouDuo.ipa
  /usr/libexec/PlistBuddy -c "Set :items:0:metadata:bundle-version $VER" ~/Sites/wuwei/dl/$SEC/douduo_manifest.plist 2>/dev/null
  sed -i '' -E "s/1\.[0-9]+\.[0-9]+/$VER/g" ~/Sites/wuwei/douduo.html
fi

installed() { grep -q 'App installed' <<<"$1"; }
r=$(xcrun devicectl device install app --device $UDID $IPA 2>&1)
if installed "$r"; then echo "✅ Duo 已装 $VER（本机）"; exit 0; fi
if scp -q -o ConnectTimeout=8 $IPA $MINI:/tmp/DouDuo-publish.ipa 2>/dev/null; then
  r=$(ssh -o ConnectTimeout=8 $MINI "xcrun devicectl device install app --device $UDID /tmp/DouDuo-publish.ipa 2>&1")
  if installed "$r"; then echo "✅ Duo 已装 $VER（Mac mini）"; exit 0; fi
fi
echo "Duo 本机和 Mac mini 都连不上，没装；局域网安装页已更新到 $VER"; exit 1

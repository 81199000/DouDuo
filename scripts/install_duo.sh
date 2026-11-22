#!/bin/zsh
# 构建签名包，并可按环境变量把安装包投递到设备 / SSH 主机 / 局域网安装页。
# 必填：DOUDUO_TEAM
# 可选：DOUDUO_DUO_UDID、DOUDUO_MINI、DOUDUO_SITE_DIR
set -uo pipefail
cd "$(dirname "$0")/.."

TEAM=${DOUDUO_TEAM:?请设置 DOUDUO_TEAM 环境变量}
UDID=${DOUDUO_DUO_UDID:-}
MINI=${DOUDUO_MINI:-}
SITE=${DOUDUO_SITE_DIR:-}
OUT=build/adhoc
ARCH=build/DouDuo.xcarchive
rm -rf "$ARCH" "$OUT"
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCH" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" archive -quiet > "$TMPDIR/dd-install-archive.log" 2>&1 \
  && xcodebuild -exportArchive -archivePath "$ARCH" -exportPath "$OUT" -exportOptionsPlist signing/ExportOptions-adhoc.plist \
       -allowProvisioningUpdates -quiet >> "$TMPDIR/dd-install-archive.log" 2>&1 \
  || { echo "签名包失败（$TMPDIR/dd-install-archive.log）"; exit 1; }
IPA=$OUT/DouDuo.ipa
VER=$(unzip -p "$IPA" Payload/DouDuo.app/Info.plist | plutil -extract CFBundleShortVersionString raw -)

# 可选：更新个人局域网安装页。路径和密钥只从环境变量 / 本地文件读取。
if [[ -n "$SITE" && -d "$SITE" ]]; then
  SEC=$(cat "$SITE/.dl_secret" 2>/dev/null)
  if [[ -n "$SEC" && -d "$SITE/dl/$SEC" ]]; then
    cp "$IPA" "$SITE/dl/$SEC/DouDuo.ipa"
    /usr/libexec/PlistBuddy -c "Set :items:0:metadata:bundle-version $VER" "$SITE/dl/$SEC/douduo_manifest.plist" 2>/dev/null
    sed -i '' -E "s/1\.[0-9]+\.[0-9]+/$VER/g" "$SITE/douduo.html"
  fi
fi

installed() { grep -q 'App installed' <<<"$1"; }
if [[ -n "$UDID" ]]; then
  r=$(xcrun devicectl device install app --device "$UDID" "$IPA" 2>&1)
  if installed "$r"; then echo "✅ 已安装 $VER（本机）"; exit 0; fi
fi

if [[ -n "$MINI" && -n "$UDID" ]]; then
  if scp -q -o ConnectTimeout=8 "$IPA" "$MINI:/tmp/DouDuo-publish.ipa" 2>/dev/null; then
    r=$(ssh -o ConnectTimeout=8 "$MINI" "xcrun devicectl device install app --device '$UDID' /tmp/DouDuo-publish.ipa 2>&1")
    if installed "$r"; then echo "✅ 已安装 $VER（远程设备）"; exit 0; fi
  fi
fi

if [[ -z "$UDID" ]]; then
  echo "✅ 已生成签名包 $IPA；未设置 DOUDUO_DUO_UDID，跳过设备安装"
  exit 0
fi
echo "设备安装失败；签名包保留在 $IPA"
exit 1

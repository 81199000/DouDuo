#!/bin/zsh
# DouDuo 发版：编译未签名 IPA → 上传 GitHub Release（所有人下载后自签安装）
# 需要：Xcode 26+、xcodegen、gh（已登录）、Vendor/VLCKit 二进制（./scripts/fetch-vlckit.sh）
# 维护者本机若有 release.local.sh（不入库，含个人签名 / OTA 配置），会改为执行它。
set -e
cd "$(dirname "$0")"
[ -x ./release.local.sh ] && exec ./release.local.sh "$@"
VER=$(grep MARKETING_VERSION project.yml | awk '{print $2}')
xcodegen generate >/dev/null
DD=${TMPDIR:-/tmp}/dd-douduo-rel
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet
rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R "$DD/Build/Products/Release-iphoneos/DouDuo.app" build/ipa/Payload/
(cd build/ipa && rm -f ../DouDuo-$VER-unsigned.ipa && zip -qry ../DouDuo-$VER-unsigned.ipa Payload)
echo "✅ build/DouDuo-$VER-unsigned.ipa"
if command -v gh >/dev/null; then
  gh release view v$VER >/dev/null 2>&1 || gh release create v$VER --title "DouDuo $VER" --notes "安装方法见 README"
  for i in 1 2 3; do gh release upload v$VER build/DouDuo-$VER-unsigned.ipa --clobber && break; echo "上传重试 $i"; sleep 5; done
fi

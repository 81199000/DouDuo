#!/bin/zsh
# 抖Duo 发版：① 未签名 IPA 传 GitHub Release（所有人自签侧载）② 自家设备 Ad Hoc OTA（局域网+外网）③ App Store Connect 包（建好 App 记录后才能传）
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
VER=$(grep MARKETING_VERSION project.yml | awk '{print $2}')
TEAM=FHMNKZL248; KEY=7KA2GLZ966; ISS=68a68e07-646c-49c7-93bc-10a5ecef513e
xcodegen generate >/dev/null
# ① 未签名
DD=$TMPDIR/dd-douduo-rel
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath $DD build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet
rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R $DD/Build/Products/Release-iphoneos/DouDuo.app build/ipa/Payload/
(cd build/ipa && rm -f ../DouDuo-$VER-unsigned.ipa && zip -qry ../DouDuo-$VER-unsigned.ipa Payload)
gh release view v$VER >/dev/null 2>&1 || gh release create v$VER --title "抖Duo $VER" --notes "见 README 安装说明"
# GitHub 上传偶发 408（家里上行只有几十 KB/s，15MB 包经常超时）→ 重试 3 次，失败就先挂自己服务器
for i in 1 2 3; do
  gh release upload v$VER build/DouDuo-$VER-unsigned.ipa --clobber && break
  echo "上传重试 $i ..."; sleep 5
done
if ! gh release view v$VER --json assets --jq '.assets[].name' | grep -q "unsigned.ipa"; then
  S0=~/Sites/wuwei; SEC0=$(cat $S0/.dl_secret)
  cp build/DouDuo-$VER-unsigned.ipa "$S0/dl/$SEC0/DouDuo-$VER-unsigned.ipa"
  echo "⚠️ GitHub 传不上去，已挂到 https://dl.remon.me/dl/$SEC0/DouDuo-$VER-unsigned.ipa"
fi
# ② Ad Hoc OTA
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -configuration Release -destination 'generic/platform=iOS' -archivePath build/DouDuo.xcarchive -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM archive -quiet
xcodebuild -exportArchive -archivePath build/DouDuo.xcarchive -exportPath build/adhoc -exportOptionsPlist signing/ExportOptions-adhoc.plist -allowProvisioningUpdates -quiet
S=~/Sites/wuwei; SEC=$(cat $S/.dl_secret)
cp build/adhoc/DouDuo.ipa $S/DouDuo.ipa; cp build/adhoc/DouDuo.ipa $S/dl/$SEC/DouDuo.ipa
sed -i '' "s#<key>bundle-version</key><string>[^<]*</string>#<key>bundle-version</key><string>$VER</string>#" $S/douduo_manifest.plist $S/dl/$SEC/douduo_manifest.plist
sed -i '' "s#v[0-9.]* · 仅限#v$VER · 仅限#" $S/douduo.html $S/dl/$SEC/douduo.html
for D in $(xcrun devicectl list devices 2>/dev/null | awk '/connected/{print $3}'); do xcrun devicectl device install app --device $D build/adhoc/DouDuo.ipa 2>&1 | grep -E "installed|ERROR" | head -1 || true; done
# ③ App Store / TestFlight（需先在 App Store Connect 建 App：Bundle ID me.rrmm.douduo）
xcodebuild -exportArchive -archivePath build/DouDuo.xcarchive -exportPath build/appstore -exportOptionsPlist signing/ExportOptions-appstore.plist -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$KEY.p8 -authenticationKeyID $KEY -authenticationKeyIssuerID $ISS -quiet
xcrun altool --upload-app --type ios --file build/appstore/DouDuo.ipa --apiKey $KEY --apiIssuer $ISS || echo "⚠️ 上传 App Store Connect 失败（App 记录未建？）"
echo "✅ 抖Duo $VER 发版完成"

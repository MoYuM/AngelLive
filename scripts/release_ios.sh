#!/bin/bash
#
# iOS 发 TestFlight 的完整流程:归档 → 导出重签 → **签名校验** → 上传。
#
# 这台机器的 Xcode 没登录 Apple 账号,所以走「归档关签名 + 导出时用描述文件离线重签」:
#   - archive 传 CODE_SIGNING_ALLOWED=NO,同时绕开「无账号」和「SPM 依赖 target 不支持
#     描述文件」两个坑(千万别在命令行全局传 PROVISIONING_PROFILE_SPECIFIER /
#     CODE_SIGN_STYLE=Manual,会套到所有 SPM target 上直接失败)。
#   - 代价是归档产物里**没有任何 entitlements 记录**:.entitlements 的内容是在签名时写进
#     二进制的,关了签名就等于把这份意图丢了。此时直接导出,Xcode 只能照描述文件生成
#     application-identifier / team-identifier 这几项基础 entitlement,**iCloud 永远进不去**
#     ——换哪份描述文件都一样。所以导出前必须先 ad-hoc 签一次把 .entitlements 写回产物,
#     导出重签时它才会被保留(并由描述文件校验)。2.1.1 build 10 缺的就是这一步。
#
# 正因为如此,导出后的签名校验是**硬关卡**:用过期/漏了 iCloud 能力的描述文件重签出来的包,
# Apple 全程不会报错、能装到设备上,然后在 CKContainer 初始化时 EXC_BREAKPOINT 启动即崩
# (2.1.1 build 10 就是这么发出去的)。校验不过一律不上传。
#
# 用法:
#   scripts/release_ios.sh              # 归档 + 导出 + 校验,不上传
#   scripts/release_ios.sh --upload     # 上述全过后再上传 TestFlight
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

WORKSPACE="AngelLive.xcworkspace"
SCHEME="AngelLive"
ARCHIVE="$ROOT/build/AngelLive.xcarchive"
EXPORT_DIR="$ROOT/build/export"
EXPORT_OPTIONS="$ROOT/scripts/ExportOptions_iOS.plist"
ENTITLEMENTS="$ROOT/iOS/AngelLive/AngelLive.entitlements"

UPLOAD=0
[ "${1:-}" = "--upload" ] && UPLOAD=1

BUILD_NUMBER=$(grep -m1 "CURRENT_PROJECT_VERSION = " iOS/AngelLive.xcodeproj/project.pbxproj | sed 's/[^0-9]*\([0-9]*\).*/\1/')
MARKETING_VERSION=$(grep -m1 "MARKETING_VERSION = " iOS/AngelLive.xcodeproj/project.pbxproj | sed 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/')
echo "==> 准备发布 $MARKETING_VERSION (build $BUILD_NUMBER)"

echo "==> 归档(关签名)"
rm -rf "$ARCHIVE"
xcodebuild archive \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  | tail -5

echo "==> 把 entitlements 写回归档产物(关签名归档会丢掉它,见文件头)"
codesign -f -s - --entitlements "$ENTITLEMENTS" "$ARCHIVE/Products/Applications/$SCHEME.app"

echo "==> 导出并用描述文件离线重签"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  | tail -3

IPA=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.ipa" | head -1)
if [ -z "$IPA" ]; then
  echo "导出没产出 ipa" >&2
  exit 1
fi

echo "==> 签名校验(不过就不上传)"
"$ROOT/scripts/verify_signed_entitlements.sh" "$IPA"

if [ "$UPLOAD" -ne 1 ]; then
  echo ""
  echo "已产出并通过校验: $IPA"
  echo "确认无误后加 --upload 上传。"
  exit 0
fi

# 凭证只放本机 scripts/.env.local(已 gitignore),不入库
if [ -f "$ROOT/scripts/.env.local" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/scripts/.env.local"
fi

if [ -z "${ASC_API_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
  echo "缺 ASC_API_KEY_ID / ASC_ISSUER_ID,请在 scripts/.env.local 里配(模板见 .env.local.example)" >&2
  exit 1
fi

echo "==> 上传 TestFlight"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

echo "==> 上传完成: $MARKETING_VERSION (build $BUILD_NUMBER)"

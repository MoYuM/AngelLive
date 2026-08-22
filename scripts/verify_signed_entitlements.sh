#!/bin/bash
#
# 校验**最终产物代码签名里实际 claim 的 entitlements**是否带着必需的 CloudKit 容器。
#
# 为什么必须有这一关:描述文件只是"允许声明"的上界,二进制实际 claim 的是 .entitlements
# 的内容,两者可以合法地不一致(claim ⊆ profile),签名与上传都不会报错。少了 iCloud
# entitlement 的包能一路通过 Apple 校验装到设备上,然后在 CKContainer 初始化时
# EXC_BREAKPOINT —— 启动即崩(线上 2.1.1 build 10 就是这样)。
#
# 用法:插在 exportArchive 与上传之间,不过就别传。
#   scripts/verify_signed_entitlements.sh <path> [容器标识]
#   <path> 可以是 .ipa / .app / .xcarchive
#
set -euo pipefail

TARGET="${1:-}"
REQUIRED_CONTAINER="${2:-iCloud.com.moyum.angellive}"

if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
  echo "用法: $0 <ipa|app|xcarchive 路径> [容器标识]" >&2
  exit 2
fi

WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

# 统一归到一个 .app 路径
case "$TARGET" in
  *.ipa)
    WORKDIR=$(mktemp -d)
    unzip -q "$TARGET" -d "$WORKDIR"
    APP=$(find "$WORKDIR/Payload" -maxdepth 1 -name "*.app" | head -1)
    ;;
  *.xcarchive)
    APP=$(find "$TARGET/Products/Applications" -maxdepth 1 -name "*.app" | head -1)
    ;;
  *.app)
    APP="$TARGET"
    ;;
  *)
    echo "不认识的产物类型: $TARGET" >&2
    exit 2
    ;;
esac

if [ -z "${APP:-}" ] || [ ! -d "$APP" ]; then
  echo "在 $TARGET 里找不到 .app" >&2
  exit 2
fi

# 主 app 与所有 App Extension 都要查:扩展有自己独立的签名与 entitlements
# (tvOS TopShelf 就单独带一份),漏查等于漏掉一半崩溃面。
TARGETS=("$APP")
while IFS= read -r appex; do
  [ -n "$appex" ] && TARGETS+=("$appex")
done < <(find "$APP" -name "*.appex" -type d 2>/dev/null)

FAILED=0

for bundle in "${TARGETS[@]}"; do
  name=$(basename "$bundle")
  entitlements=$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)

  if [ -z "$entitlements" ]; then
    echo "✘ $name: 读不出代码签名 entitlements"
    FAILED=1
    continue
  fi

  # PlistBuddy 读不到 key 时退出非零,用它判断"有没有声明"
  containers=$(echo "$entitlements" | /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers" /dev/stdin 2>/dev/null || true)
  services=$(echo "$entitlements" | /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-services" /dev/stdin 2>/dev/null || true)

  if ! echo "$containers" | grep -qF "$REQUIRED_CONTAINER"; then
    echo "✘ $name: 签名里没有 CloudKit 容器 $REQUIRED_CONTAINER —— 这个包一碰 CKContainer 就会启动即崩"
    FAILED=1
    continue
  fi

  if ! echo "$services" | grep -qF "CloudKit"; then
    echo "✘ $name: 声明了容器但 icloud-services 里没有 CloudKit"
    FAILED=1
    continue
  fi

  echo "✔ $name: $REQUIRED_CONTAINER + CloudKit 已在签名里"
done

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "签名校验未通过,禁止上传。先查:导出用的描述文件是不是漏了 iCloud 能力,"
  echo "以及本机是否存在同名但内容不同的描述文件(ExportOptions 按 Name 匹配会选错)。"
  exit 1
fi

echo ""
echo "签名校验通过,可以上传。"

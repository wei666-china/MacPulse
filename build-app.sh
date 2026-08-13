#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd -P "$(dirname "$0")" && pwd)"
BUILD_MODE="${1:-release}"
STAGING_ROOT="$(mktemp -d /private/tmp/macpulse-build.XXXXXX)"
APP_PATH="$STAGING_ROOT/MacPulse.app"
VERIFY_ROOT="$STAGING_ROOT/verify"
ZIP_PATH="$PROJECT_ROOT/outputs/MacPulse.zip"
SOURCE_ZIP_PATH="$PROJECT_ROOT/outputs/MacPulse-Source.zip"
ASSET_WORK="$PROJECT_ROOT/.build-app/Assets.xcassets"
ICON_WORK="$ASSET_WORK/AppIcon.appiconset"
export CLANG_MODULE_CACHE_PATH="$STAGING_ROOT/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$STAGING_ROOT/cache/swiftpm"
export XDG_CACHE_HOME="$STAGING_ROOT/cache/xdg"
trap 'rm -rf "$STAGING_ROOT"' EXIT

cd "$PROJECT_ROOT"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$XDG_CACHE_HOME"

swift build --disable-sandbox -c "$BUILD_MODE" --product MacPulse
swift build --disable-sandbox -c "$BUILD_MODE" --product MacPulseCollector
BIN_PATH="$(swift build --disable-sandbox -c "$BUILD_MODE" --show-bin-path)"

rm -rf \
  "$PROJECT_ROOT/outputs/MacPulse.app" \
  "$ZIP_PATH" \
  "$SOURCE_ZIP_PATH" \
  "$PROJECT_ROOT/.build-app"
mkdir -p \
  "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Helpers" \
  "$APP_PATH/Contents/Resources" \
  "$ICON_WORK"
install -m 644 "$PROJECT_ROOT/Resources/Assets.xcassets/Contents.json" "$ASSET_WORK/Contents.json"
install -m 644 "$PROJECT_ROOT/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" "$ICON_WORK/Contents.json"

install -m 755 "$BIN_PATH/MacPulse" "$APP_PATH/Contents/MacOS/MacPulse"
install -m 755 "$BIN_PATH/MacPulseCollector" "$APP_PATH/Contents/Helpers/MacPulseCollector"
install -m 644 "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
install -m 644 "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"

# 本地化:中文是源语言(代码里的 key 本身),英文翻译表随包分发。
# 放在 Bundle.main 的 Resources 下,SwiftUI 字面量与 String(localized:) 都能查到。
mkdir -p "$APP_PATH/Contents/Resources/en.lproj" "$APP_PATH/Contents/Resources/zh-Hans.lproj"
install -m 644 "$PROJECT_ROOT/Resources/en.lproj/Localizable.strings" \
  "$APP_PATH/Contents/Resources/en.lproj/Localizable.strings"

swiftc "$PROJECT_ROOT/Tools/IconGenerator.swift" \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -o "$PROJECT_ROOT/.build-app/icon-generator"
"$PROJECT_ROOT/.build-app/icon-generator" "$PROJECT_ROOT/.build-app/icon-source.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PROJECT_ROOT/.build-app/icon-source.png" \
    --out "$ICON_WORK/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$PROJECT_ROOT/.build-app/icon-source.png" \
    --out "$ICON_WORK/icon_${size}x${size}@2x.png" >/dev/null
done
xcrun actool "$ASSET_WORK" \
  --compile "$APP_PATH/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$PROJECT_ROOT/.build-app/asset-info.plist" \
  >/dev/null

# Finder metadata and resource forks are not part of the signed bundle. If they
# are added before or during archiving, macOS rejects the ad-hoc signature.
xattr -cr "$APP_PATH"
# --options runtime 开启强化运行时:库校验挡掉同权限进程的动态库注入。
# 我们只 dlopen 苹果自签的系统库(libIOReport),不受影响。
#
# 签名身份分两档:
# - 默认 "-"(ad-hoc):本地自用,零门槛
# - 设了 MACPULSE_SIGN_IDENTITY(如 "Developer ID Application: ..."):
#   对外分发档,加可信时间戳,配合下方公证步骤产出「下载即开」的包
SIGN_IDENTITY="${MACPULSE_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --options runtime --sign - "$APP_PATH"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
fi
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

(
  cd "$STAGING_ROOT"
  COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "MacPulse.app" "$ZIP_PATH"
)

# Verify the artifact users actually receive, not only the pre-archive bundle.
mkdir -p "$VERIFY_ROOT"
ditto -x -k "$ZIP_PATH" "$VERIFY_ROOT"
if unzip -Z1 "$ZIP_PATH" | grep -qE '(^|/)\._'; then
  print -u2 "归档包含 AppleDouble 文件，签名可能损坏。"
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$VERIFY_ROOT/MacPulse.app"

ditto --norsrc "$VERIFY_ROOT/MacPulse.app" "$PROJECT_ROOT/outputs/MacPulse.app"
xattr -cr "$PROJECT_ROOT/outputs/MacPulse.app"

# 公证(可选):三个环境变量齐了才跑,缺任何一个就静默跳过——
# 本地日常构建不受影响。凭据用 App Store Connect API 密钥(.p8),
# 不经手任何密码。公证通过后把票据钉进 App 再重打 zip,
# 用户离线首启也能过 Gatekeeper。
if [[ -n "${MACPULSE_NOTARY_KEY_ID:-}" && -n "${MACPULSE_NOTARY_ISSUER:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  NOTARY_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${MACPULSE_NOTARY_KEY_ID}.p8"
  if [[ -f "$NOTARY_KEY" ]]; then
    print "提交公证(notarytool)……"
    xcrun notarytool submit "$ZIP_PATH" \
      --key "$NOTARY_KEY" \
      --key-id "$MACPULSE_NOTARY_KEY_ID" \
      --issuer "$MACPULSE_NOTARY_ISSUER" \
      --wait
    xcrun stapler staple "$PROJECT_ROOT/outputs/MacPulse.app"
    (
      cd "$PROJECT_ROOT/outputs"
      rm -f "$ZIP_PATH"
      COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "MacPulse.app" "$ZIP_PATH"
    )
    print "公证完成,票据已钉入,zip 已重打。"
  else
    print -u2 "缺公证密钥文件:$NOTARY_KEY"
    exit 1
  fi
fi

SOURCE_STAGING="$STAGING_ROOT/MacPulse-Source"
mkdir -p "$SOURCE_STAGING"
for item in \
  Package.swift \
  README.md \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  build-app.sh \
  docs \
  Resources \
  Sources \
  Tests \
  Tools; do
  cp -R "$PROJECT_ROOT/$item" "$SOURCE_STAGING/"
done
(
  cd "$STAGING_ROOT"
  COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "MacPulse-Source" "$SOURCE_ZIP_PATH"
)

print "Archive: $ZIP_PATH"
print "App: $PROJECT_ROOT/outputs/MacPulse.app"
print "Source: $SOURCE_ZIP_PATH"

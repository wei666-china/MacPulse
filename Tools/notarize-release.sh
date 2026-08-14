#!/bin/zsh
# 一键出正式包:签名 → 公证 → 钉票据 → 重发 Release。
#
# 前置(只做一次,必须由账号持有人本人在 Xcode 里点):
#   Xcode → Settings → Accounts → 选 Apple ID → Manage Certificates…
#   → 左下「+」→ Developer ID Application
# 苹果规定这张证书只能账号持有人签发,API 无法代劳。
#
# 用法:./Tools/notarize-release.sh [tag]   默认 tag = 最新的 v* 发布 tag

set -e
setopt no_nomatch 2>/dev/null || true

TAG="${1:-$(git describe --tags --abbrev=0 --match 'v*')}"
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"

# 1. 找证书:名字里带 Developer ID Application 的那张
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | head -1 \
  | sed -E 's/.*"(.*)"/\1/')

if [[ -z "$IDENTITY" ]]; then
  print -u2 "找不到 Developer ID Application 证书。"
  print -u2 "请先在 Xcode → Settings → Accounts → Manage Certificates → + 里生成,"
  print -u2 "然后重跑本脚本。"
  exit 1
fi
print "签名身份:$IDENTITY"

# 2. 带签名与公证凭据构建(build-app.sh 内部按环境变量决定走分发档)
export MACPULSE_SIGN_IDENTITY="$IDENTITY"
export MACPULSE_NOTARY_KEY_ID="55VMCDZAFK"
export MACPULSE_NOTARY_ISSUER="4e4090b8-e5e0-47a7-b815-f0708a4cb12b"
./build-app.sh release

# 3. 验证:公证票据在不在,Gatekeeper 认不认
print "\n=== 公证票据 ==="
xcrun stapler validate outputs/MacPulse.app
print "\n=== Gatekeeper 评估(应为 accepted / Notarized Developer ID)==="
spctl -a -vvv -t install outputs/MacPulse.app

# 4. 重发 Release 资产并更新校验码
SHA=$(shasum -a 256 outputs/MacPulse.zip | cut -d' ' -f1)
print "\nSHA256: $SHA"
gh release upload "$TAG" outputs/MacPulse.zip --clobber
print "\n完成:下载后双击即可打开,无需右键。"

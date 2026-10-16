#!/bin/bash
# 在你的 Mac 上运行：拉取最新代码 -> 构建 Watch App -> 安装到配对的 Apple Watch
# 依赖：Xcode 27.0（/Applications/Xcode-27.0.0.app）、手表已配对且开了开发者模式
# 用法：bash scripts/deploy-watch.sh
#   如自动找不到手表：WATCH_ID=<设备标识> bash scripts/deploy-watch.sh
set -euo pipefail

cd "$(dirname "$0")/.."   # 仓库根目录

# 1. 拉最新（仓库还没推 GitHub 时跳过，用本地代码构建）
if git remote get-url origin >/dev/null 2>&1; then
  git pull --ff-only
else
  echo "未配置 git remote，跳过拉取，用本地代码构建。"
fi

# 2. 生成 App 图标（macOS 自带 sips，无需装依赖）
python3 scripts/generate-icons.py

# 3. 构建（签名沿用工程里已配好的 Personal Team，不要改 Bundle ID）
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
DERIVED=/private/tmp/wrist-interpreter-watch-build
rm -rf "$DERIVED"
xcodebuild -project WristInterpreter.xcodeproj \
  -scheme WristInterpreterWatch \
  -configuration Debug \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath "$DERIVED" \
  build

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "WristInterpreterWatch.app" | head -1)
[ -n "$APP" ] || { echo "没找到构建产物，构建可能失败"; exit 1; }
codesign --verify --deep --strict "$APP" && echo "签名校验通过"

# 3. 安装到手表
if [ -z "${WATCH_ID:-}" ]; then
  WATCH_ID=$(devicectl list devices 2>/dev/null | grep -i "watch" | head -1 | awk '{print $1}' || true)
fi
[ -n "${WATCH_ID:-}" ] || { echo "没找到手表：请解锁手表、靠近 Mac 后重试，或用 WATCH_ID=<设备标识> 指定"; exit 1; }
devicectl device install app --device "$WATCH_ID" "$APP"
echo "安装完成。到手表上点开始翻译实测；结束后续看验收清单 docs/acceptance.md。"

#!/bin/bash
# 在你的 Mac 上运行：拉取最新代码 -> 生成图标 -> 构建手表+手机 App -> 分别安装
# 依赖：Xcode 27.0（/Applications/Xcode-27.0.0.app）、手机手表已配对且开了开发者模式
# 用法：bash scripts/deploy-watch.sh
#   如自动找不到设备：WATCH_ID=<标识> IPHONE_ID=<标识> bash scripts/deploy-watch.sh
set -euo pipefail

cd "$(dirname "$0")/.."   # 仓库根目录

# 1. 拉最新（仓库还没推 GitHub 时跳过，用本地代码构建），然后重新生成工程
#    （保证新增的 Swift 文件进入编译；幂等，重复运行无变化）
#    注意：脚本更新了自己后必须重跑新版本，否则 bash 继续执行的是旧缓冲内容。
if git remote get-url origin >/dev/null 2>&1; then
  BEFORE=$(git rev-parse HEAD)
  git pull --ff-only
  if [ "$(git rev-parse HEAD)" != "$BEFORE" ]; then
    echo "脚本已更新，重新执行新版本…"
    exec bash "$0" "$@"
  fi
else
  echo "未配置 git remote，跳过拉取，用本地代码构建。"
fi
python3 scripts/generate-project.py

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
  -allowProvisioningUpdates \
  build

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "WristInterpreterWatch.app" | head -1)
[ -n "$APP" ] || { echo "没找到构建产物，构建可能失败"; exit 1; }
codesign --verify --deep --strict "$APP" && echo "签名校验通过"
APPEX_IN_APP="$APP/PlugIns/WristInterpreterWidget.appex"
if [ -d "$APPEX_IN_APP" ]; then
  echo "小组件扩展已打进安装包"
else
  echo "警告：小组件扩展没打进安装包，表盘上会找不到腕译"
  find "$DERIVED/Build/Products" -maxdepth 5 -name "WristInterpreterWidget.appex" 2>/dev/null | head -5
fi

# 3. 安装到手表
# 从 devicectl 列表里按标识格式（8位-16位）提取设备，名字里有空格也不怕
detect_device_id() {
  devicectl list devices 2>/dev/null | grep -i "$1" | grep -oE '[0-9A-Za-z]{8}-[0-9A-Za-z]{16}' | head -1 || true
}
if [ -z "${WATCH_ID:-}" ]; then
  WATCH_ID=$(detect_device_id "watch")
fi
[ -n "${WATCH_ID:-}" ] || { echo "没找到手表：请确认手表已解锁、开开发者模式、与 Mac 在同一 Wi-Fi 下，然后重试；或用 WATCH_ID=<设备标识> 指定（devicectl list devices 查看）"; exit 1; }
devicectl device install app --device "$WATCH_ID" "$APP"
# 4. 构建手机 App 并安装到手机（新图标）
xcodebuild -project WristInterpreter.xcodeproj \
  -scheme WristInterpreter \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

IPHONE_APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "WristInterpreter.app" | head -1)
[ -n "$IPHONE_APP" ] || { echo "没找到手机构建产物，构建可能失败"; exit 1; }
codesign --verify --deep --strict "$IPHONE_APP" && echo "手机 App 签名校验通过"
if [ -z "${IPHONE_ID:-}" ]; then
  IPHONE_ID=$(detect_device_id "iphone")
fi
[ -n "${IPHONE_ID:-}" ] || { echo "没找到手机：请解锁手机、靠近 Mac 后重试，或用 IPHONE_ID=<设备标识> 指定（devicectl list devices 查看）"; exit 1; }
devicectl device install app --device "$IPHONE_ID" "$IPHONE_APP"
echo "手机 App 安装完成"

echo "全部完成。手表上点开始翻译实测；结束后续看验收清单 docs/acceptance.md。"

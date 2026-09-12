#!/usr/bin/env bash
# ============================================================
#  同步原生源码 → Android 工程
# ============================================================
#
# 背景：
#   android/ 目录被 .gitignore 排除（它是 Capacitor 生成的构建工程，
#   体积大且可重现）。但我们自己写的 5 个 Java 文件必须进版本库，
#   所以它们存在 native-src/ 里。
#
#   新克隆仓库后，`npx cap add android` 生成的工程里没有这些文件，
#   必须跑一次本脚本把它们拷回去。
#
# 用法：
#   cd apk/agent-app && bash sync-native.sh
# ============================================================

set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/native-src/android/app/src/main"
DST="$HERE/android/app/src/main"

if [ ! -d "$HERE/android" ]; then
  echo "✗ 没有 android/ 目录。请先执行："
  echo "    cd apk/agent-app && npx cap add android"
  exit 1
fi

echo "同步原生源码..."
echo "  从: $SRC"
echo "  到: $DST"

# Java 源码
mkdir -p "$DST/java/com/prism/agent"
cp -v "$SRC/java/com/prism/agent/"*.java "$DST/java/com/prism/agent/"

# 资源（网络安全配置）
mkdir -p "$DST/res/xml"
cp -v "$SRC/res/xml/"*.xml "$DST/res/xml/"

# AndroidManifest 用我们自己那份（含服务/广播/权限声明）
cp -v "$SRC/AndroidManifest.xml" "$DST/AndroidManifest.xml"

echo ""
echo "✓ 完成。接下来："
echo "    npx cap sync android"
echo "    cd android && ./gradlew.bat assembleDebug"

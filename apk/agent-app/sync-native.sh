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

# ------------------------------------------------------------
# 版本号
#
# ★ 为什么要在同步脚本里改版本号：
#   android/ 是 .gitignore 的生成目录，里面的 build.gradle 不入库。
#   手动改一次、下次重新生成就丢了，还会让「设备上到底装的是哪版」
#   变得没法判断（我们踩过：v1.2 和 v1.3 的 prism_rest 行为不同，
#   但设备上报的 app_ver 一直是 1.0，只能靠行为反推）。
#
#   现在版本号由 native-src/VERSION 决定（第一行 versionCode，
#   第二行 versionName），每次同步都会写进 build.gradle。
#   被控端心跳会把 versionName 上报到云端，控制台能直接看到。
# ------------------------------------------------------------
VER_FILE="$HERE/native-src/VERSION"
if [ -f "$VER_FILE" ]; then
  VCODE="$(sed -n '1p' "$VER_FILE" | tr -d ' \r')"
  VNAME="$(sed -n '2p' "$VER_FILE" | tr -d ' \r')"
  if [ -n "$VCODE" ] && [ -n "$VNAME" ]; then
    GRADLE="$HERE/android/app/build.gradle"
    if [ -f "$GRADLE" ]; then
      sed -i "s/versionCode [0-9]\+/versionCode $VCODE/" "$GRADLE"
      sed -i "s/versionName \"[^\"]*\"/versionName \"$VNAME\"/" "$GRADLE"
      echo "✓ 版本号已写入 build.gradle: versionCode=$VCODE versionName=$VNAME"
    fi
  fi
fi

echo ""
echo "✓ 完成。接下来："
echo "    npx cap sync android"
echo "    cd android && ./gradlew.bat assembleDebug"

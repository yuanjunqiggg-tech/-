# Prism 被控端 · Android 工程

跑在安卓云手机上的常驻 App，接收云端指令并驱动本机 Prism。

## 快速构建

```bash
# 0) 环境（只需一次）
#    JDK 17 + Android SDK 34 + Node 20+
export JAVA_HOME="C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot"
export ANDROID_HOME="C:\Users\16650\android-sdk"

# 1) 安装依赖
npm install

# 2) 生成 Android 工程（首次，或 android/ 被删后）
npx cap add android

# 3) 把我们的原生源码拷进去（★ 关键步骤，新克隆必做）
bash sync-native.sh

# 4) 同步 Web 资源
npx cap sync android

# 5) 配置 SDK 路径（必须用正斜杠！）
echo 'sdk.dir=C:/Users/16650/android-sdk' > android/local.properties

# 6) 编译
cd android && ./gradlew.bat assembleDebug
```

产物：`android/app/build/outputs/apk/debug/app-debug.apk`

## 目录说明

```
agent-app/
├── www/index.html          ← 界面（由 ../../web/agent.html 拷来）
├── native-src/             ← ★ 我们写的原生源码（进版本库）
│   └── android/app/src/main/
│       ├── java/com/prism/agent/
│       │   ├── MainActivity.java      主界面 + 权限申请
│       │   ├── AgentService.java      前台保活服务
│       │   ├── BootReceiver.java      开机自启
│       │   ├── AgentPrefs.java        偏好存储
│       │   └── PrismNativePlugin.java JS ↔ 原生桥
│       ├── AndroidManifest.xml        权限 / 服务 / 广播声明
│       └── res/xml/network_security_config.xml
├── android/                ← Capacitor 生成的工程（.gitignore 排除）
├── capacitor.config.json
├── sync-native.sh          ← 把 native-src 拷进 android/
└── package.json
```

> **为什么原生源码放在 `native-src/` 而不是直接改 `android/`？**
> `android/` 被 .gitignore 排除（Capacitor 生成的构建工程，体积大且可重现）。
> 我们的 5 个 Java 文件必须进版本库，所以独立存放，用 `sync-native.sh` 同步。

## 踩坑记录

| 现象 | 原因 | 解法 |
|------|------|------|
| `文件名、目录名或卷标语法不正确` | `local.properties` 里写了 `sdk.dir=C\:\Users\...`，Java properties 把 `\:` 解析成 `:`、`\U` 解析成 `U`，拼出非法路径 | **必须用正斜杠** `C:/Users/...` |
| `onResume() 无法覆盖` | `BridgeActivity.onResume()` 是 `public`，子类写 `protected` 权限更小 | 改成 `public` |
| APK 里读不到电量、拉不起服务 | Capacitor 6 的插件挂在 `Capacitor.Plugins` 上，不是 `window.PrismNative` | 见 `web/agent.html` 的 `nativePlugin()` |
| 编译时内存飙高 | Gradle 默认堆较大；本机内存有硬件故障，高占用易触发蓝屏 | `gradle.properties` 压到 `-Xmx1024m` 并关并行 |

## 安装到云手机后必做

1. 授予**通知权限**（Android 13+ 没有它前台服务起不来）
2. 电池优化设为**「无限制」**（App 内有「去设置」按钮）
3. 允许**自启动**（App 内有「去设置」按钮）
4. 打开云手机平台的**「后台保活」**开关

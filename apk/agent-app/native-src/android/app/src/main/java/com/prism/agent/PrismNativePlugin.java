package com.prism.agent;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * ============================================================
 * 设备信息桥 · Capacitor 插件
 * ============================================================
 *
 * WebView 里拿不到电量、机型这些原生信息，也没法启动前台服务。
 * 这个插件就是 JS 与原生之间的那层桥：
 *
 *   PrismNative.getInfo()      → 机型 / 系统版本 / 电量 / 是否充电
 *   PrismNative.startService() → 拉起前台保活服务
 *   PrismNative.stopService()  → 停止服务
 *   PrismNative.serviceState() → 服务当前是否在跑
 *   PrismNative.openBatterySettings() → 跳到电池优化设置页
 *
 * JS 侧用法见 agent.html 的 collectMeta() / checkKeepalive()。
 */
@CapacitorPlugin(name = "PrismNative")
public class PrismNativePlugin extends Plugin {

    private static final String TAG = "PrismAgent";

    // ============================================================
    // 设备信息
    // ============================================================
    @PluginMethod
    public void getInfo(PluginCall call) {
        JSObject o = new JSObject();

        try {
            o.put("platform", "android");
            o.put("model", Build.MANUFACTURER + " " + Build.MODEL);
            o.put("brand", Build.BRAND);
            o.put("device", Build.DEVICE);
            o.put("osVersion", Build.VERSION.RELEASE);
            o.put("sdkInt", Build.VERSION.SDK_INT);
            o.put("battery", readBattery());
            o.put("charging", isCharging());
            o.put("serviceRunning", AgentService.running);
            o.put("appVersion", appVersion());
        } catch (Exception e) {
            Log.w(TAG, "读取设备信息失败：" + e.getMessage());
        }

        call.resolve(o);
    }

    @SuppressWarnings("deprecation")
    private int readBattery() {
        try {
            BatteryManager bm =
                    (BatteryManager) getContext().getSystemService(Context.BATTERY_SERVICE);
            if (bm == null) return -1;
            int v = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
            return v;   // 读不到会是 0，但比 -1 更可能真实
        } catch (Exception e) {
            return -1;
        }
    }

    private boolean isCharging() {
        try {
            IntentFilter f = new IntentFilter(Intent.ACTION_BATTERY_CHANGED);
            Intent i = getContext().registerReceiver(null, f);
            if (i == null) return false;
            int status = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
            return status == BatteryManager.BATTERY_STATUS_CHARGING
                    || status == BatteryManager.BATTERY_STATUS_FULL;
        } catch (Exception e) {
            return false;
        }
    }

    private String appVersion() {
        try {
            return getContext().getPackageManager()
                    .getPackageInfo(getContext().getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "1.0.0";
        }
    }

    // ============================================================
    // 服务控制
    // ============================================================
    @PluginMethod
    public void startService(PluginCall call) {
        try {
            AgentService.start(getContext());
            JSObject o = new JSObject();
            o.put("ok", true);
            call.resolve(o);
        } catch (Exception e) {
            call.reject("启动服务失败：" + e.getMessage());
        }
    }

    @PluginMethod
    public void stopService(PluginCall call) {
        try {
            AgentService.stop(getContext());
            JSObject o = new JSObject();
            o.put("ok", true);
            call.resolve(o);
        } catch (Exception e) {
            call.reject("停止服务失败：" + e.getMessage());
        }
    }

    @PluginMethod
    public void serviceState(PluginCall call) {
        JSObject o = new JSObject();
        o.put("running", AgentService.running);
        o.put("userStopped", AgentPrefs.isUserStopped(getContext()));
        call.resolve(o);
    }

    // ============================================================
    // 设置页跳转（保活三件套里用户最容易漏的两项）
    // ============================================================

    /** 跳到「电池优化」列表，让用户把自己的 App 设为不优化 */
    @PluginMethod
    public void openBatterySettings(PluginCall call) {
        try {
            Intent i = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            call.resolve();
        } catch (Exception e) {
            call.reject("无法打开电池设置：" + e.getMessage());
        }
    }

    /** 跳到本应用的详情页（自启动 / 权限开关通常在这里） */
    @PluginMethod
    public void openAppSettings(PluginCall call) {
        try {
            Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
            i.setData(android.net.Uri.parse("package:" + getContext().getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            call.resolve();
        } catch (Exception e) {
            call.reject("无法打开应用设置：" + e.getMessage());
        }
    }

    // ============================================================
    // ★ Prism 引擎桥（拉起 / 探活 / 确保就绪）
    // ============================================================
    //
    // 背景：用户要求「操纵 APK 自己的数据，而不是网页的」。
    // 拆包已证实 APK 界面 = WebView 加载 127.0.0.1:8080，二者是同一个
    // Go 引擎、同一份数据。所以只要保证 Prism 进程活着，我们通过 8080
    // 下发的操作与用户在 APK 里点按钮完全等价。
    //
    // 这三个方法就是给 JS 侧用的「保证活着」的能力。
    //
    // ★ 全部丢到单线程池执行：
    //   PrismBridge.alive() 有网络请求，主线程直接跑会
    //   NetworkOnMainThreadException；ensure() 还会 sleep 等引擎起来。
    // ============================================================

    private java.util.concurrent.ExecutorService prismExecutor;

    private java.util.concurrent.ExecutorService exe() {
        if (prismExecutor == null || prismExecutor.isShutdown()) {
            prismExecutor = java.util.concurrent.Executors.newSingleThreadExecutor();
        }
        return prismExecutor;
    }

    /**
     * 查询 Prism 状态：是否安装、8080 是否响应。
     * 返回 { installed, alive, port }
     */
    @PluginMethod
    public void prismStatus(final PluginCall call) {
        exe().execute(() -> {
            try {
                int port = call.getInt("port", 8080);
                JSObject o = new JSObject();
                o.put("installed", PrismBridge.isInstalled(getContext()));
                o.put("alive", PrismBridge.alive(port, 1500));
                o.put("port", port);
                o.put("pkg", PrismBridge.PRISM_PKG);
                call.resolve(o);
            } catch (Throwable t) {
                call.reject("查询 Prism 状态失败：" + t.getMessage());
            }
        });
    }

    /**
     * 拉起 Prism APK（不管它现在活不活）。
     * 返回 { ok, how }
     */
    @PluginMethod
    public void prismLaunch(final PluginCall call) {
        exe().execute(() -> {
            try {
                String how = PrismBridge.launch(getContext());
                JSObject o = new JSObject();
                o.put("ok", how != null);
                o.put("how", how);
                call.resolve(o);
            } catch (Throwable t) {
                call.reject("拉起 Prism 失败：" + t.getMessage());
            }
        });
    }

    /**
     * 确保 Prism 引擎就绪：不活着就拉起并等待。
     * 返回 { ok, how, message, costMs }
     *
     * @param call.port   端口，默认 8080
     * @param call.waitMs 拉起后最长等待毫秒，默认 20000
     */
    @PluginMethod
    public void prismEnsure(final PluginCall call) {
        exe().execute(() -> {
            try {
                int port = call.getInt("port", 8080);
                int waitMs = call.getInt("waitMs", 20000);
                PrismBridge.Result r = PrismBridge.ensure(getContext(), port, waitMs);
                JSObject o = new JSObject();
                o.put("ok", r.ok);
                o.put("how", r.how);
                o.put("message", r.message);
                o.put("costMs", r.costMs);
                o.put("port", port);
                call.resolve(o);
            } catch (Throwable t) {
                call.reject("确保 Prism 就绪失败：" + t.getMessage());
            }
        });
    }

    /**
     * 把 WebView 里注册到的设备凭据交给原生层，并立刻开起原生轮询。
     *
     * JS 在 /device/register 成功后调这个。没有它，AgentService 里的
     * NativePoller 不知道 device_id/token，就只能干等。
     */
    @PluginMethod
    public void setCredentials(final PluginCall call) {
        try {
            final String id = call.getString("device_id", "");
            final String token = call.getString("token", "");
            final String endpoint = call.getString("endpoint", "");
            final int port = call.getInt("port", 8080);
            final String name = call.getString("name", "");

            if (id == null || id.isEmpty() || token == null || token.isEmpty()) {
                call.reject("缺少 device_id 或 token");
                return;
            }

            AgentPrefs.setCredentials(getContext(), id, token, endpoint, port, name);

            // 服务没起就顺便起一下；已起的话 NativePoller.start() 自己会忽略
            AgentService.start(getContext());
            NativePoller.get(getContext()).start();

            JSObject o = new JSObject();
            o.put("ok", true);
            o.put("nativePolling", NativePoller.get(getContext()).isRunning());
            call.resolve(o);
        } catch (Throwable t) {
            call.reject("保存凭据失败：" + t.getMessage());
        }
    }

    /** 原生轮询是否在跑（给界面显示用） */
    @PluginMethod
    public void nativePollerState(PluginCall call) {
        JSObject o = new JSObject();
        o.put("running", NativePoller.get(getContext()).isRunning());
        o.put("hasCredentials", AgentPrefs.hasCredentials(getContext()));
        call.resolve(o);
    }

    @Override
    protected void handleOnDestroy() {
        if (prismExecutor != null && !prismExecutor.isShutdown()) {
            prismExecutor.shutdownNow();
            prismExecutor = null;
        }
        super.handleOnDestroy();
    }
}

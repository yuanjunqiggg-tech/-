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
}

package com.prism.agent;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.Log;
import android.view.View;
import android.webkit.WebView;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.getcapacitor.BridgeActivity;

/**
 * ============================================================
 * Prism 被控端 · 主界面
 * ============================================================
 *
 * 只是一个承载 WebView 的壳。真正的事情都在 www/index.html 里做。
 *
 * 这里额外做了三件云手机场景下必须做的事：
 *   1. 进 App 就申请通知权限（Android 13+ 没有它前台服务起不来）
 *   2. 申请电池优化白名单（否则息屏后轮询会被掐）
 *   3. 自动拉起前台服务
 */
public class MainActivity extends BridgeActivity {

    private static final String TAG = "PrismAgent";
    private static final int REQ_NOTIFY = 2001;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        // 插件必须在 super.onCreate 之前注册
        registerPlugin(PrismNativePlugin.class);

        super.onCreate(savedInstanceState);

        setupWebView();
        requestNotifyPermission();
        ensureServiceRunning();
    }

    // ============================================================
    // WebView 调优
    // ============================================================
    private void setupWebView() {
        try {
            WebView wv = getBridge().getWebView();
            if (wv == null) return;

            // 允许混合内容：本地 Prism 是 http://127.0.0.1:8080
            wv.getSettings().setMixedContentMode(
                    android.webkit.WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);

            // 允许 localStorage（设备 ID / token 存在这里）
            wv.getSettings().setDomStorageEnabled(true);
            wv.getSettings().setDatabaseEnabled(true);

            // 不要省电暂停 JS 定时器 —— 省电模式会冻结轮询
            wv.getSettings().setJavaScriptEnabled(true);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                wv.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false);
            }

            // 让 WebView 铺满
            wv.setFitsSystemWindows(true);
        } catch (Exception e) {
            Log.w(TAG, "WebView 配置失败：" + e.getMessage());
        }
    }

    // ============================================================
    // 权限
    // ============================================================
    private void requestNotifyPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return;
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED) {
            return;
        }
        ActivityCompat.requestPermissions(
                this, new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        super.onRequestPermissionsResult(code, perms, results);
        if (code == REQ_NOTIFY) {
            boolean granted = results.length > 0
                    && results[0] == PackageManager.PERMISSION_GRANTED;
            Log.i(TAG, "通知权限：" + (granted ? "已授予" : "被拒绝"));
        }
    }

    private boolean isIgnoringBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true;
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        if (pm == null) return true;
        return pm.isIgnoringBatteryOptimizations(getPackageName());
    }

    /**
     * 请求把本 App 加入电池优化白名单。
     * 用系统弹窗（ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS），
     * 比让用户自己去设置里翻找友好得多。
     */
    public void requestBatteryExemption(View v) {
        if (isIgnoringBatteryOptimizations()) return;
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(Uri.parse("package:" + getPackageName()));
            startActivity(i);
        } catch (Exception e) {
            // 部分 ROM 不支持直接请求，退回列表页
            try {
                startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (Exception ignored) {
            }
        }
    }

    // ============================================================
    // 服务
    // ============================================================
    private void ensureServiceRunning() {
        if (AgentPrefs.isUserStopped(this)) {
            Log.i(TAG, "用户曾手动停用，不自动拉起");
            return;
        }
        try {
            AgentService.start(this);
            Log.i(TAG, "前台服务已拉起");
        } catch (Exception e) {
            Log.e(TAG, "拉起前台服务失败：" + e.getMessage());
        }
    }

    @Override
    public void onResume() {   // 必须是 public —— BridgeActivity 里声明为 public，protected 会编译失败
        super.onResume();
        // 回到前台时确认服务还在
        if (!AgentService.running && !AgentPrefs.isUserStopped(this)) {
            ensureServiceRunning();
        }
    }
}

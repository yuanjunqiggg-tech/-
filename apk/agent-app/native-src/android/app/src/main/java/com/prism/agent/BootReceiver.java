package com.prism.agent;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

/**
 * 开机自启。
 *
 * 云手机重启（或平台重置）后，如果不拉起服务，设备就会一直显示离线，
 * 用户必须手动打开 App —— 这在远程场景下是致命的。
 *
 * 除了 BOOT_COMPLETED，还监听几个国产 ROM 常用的"伪开机"广播
 * （如 HTC/小米的 QUICKBOOT_POWERON），这类 ROM 不一定发标准广播。
 */
public class BootReceiver extends BroadcastReceiver {

    private static final String TAG = "PrismAgent";

    @Override
    public void onReceive(Context ctx, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        if (action == null) return;

        boolean isBoot =
                Intent.ACTION_BOOT_COMPLETED.equals(action)
                        || "android.intent.action.QUICKBOOT_POWERON".equals(action)
                        || "com.htc.intent.action.QUICKBOOT_POWERON".equals(action)
                        || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)
                        || Intent.ACTION_LOCKED_BOOT_COMPLETED.equals(action);

        if (!isBoot) return;

        // 用户主动停用过就不打扰
        if (AgentPrefs.isUserStopped(ctx)) {
            Log.i(TAG, "开机广播到达，但用户已手动停用，跳过");
            return;
        }

        Log.i(TAG, "开机广播到达：" + action + "，拉起前台服务");
        AgentPrefs.setLastBoot(ctx, System.currentTimeMillis());

        // 走 AgentService.startSafely：
        // 部分 ROM 在开机广播阶段也不允许起前台服务，
        // 抛异常会连带把广播接收流程搞崩，必须吞掉。
        if (!AgentService.startSafely(ctx)) {
            Log.w(TAG, "开机自启未成功，等用户下次打开 App 时再拉起");
        }
    }
}

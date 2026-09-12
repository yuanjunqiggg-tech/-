package com.prism.agent;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * 被控端的轻量偏好存储。
 *
 * 目前只存两类东西：
 *   1. 用户是否主动停用了服务（stop 之后不再自动拉起，否则会变成"杀不死的流氓"
 *      —— 用户会无法关闭，体验很糟）
 *   2. 保活相关的自检计数
 *
 * 注意：设备 ID / token / 网关地址这些「业务配置」存在 WebView 的
 * localStorage 里（由 agent.html 管理），不在这里重复存一份，
 * 避免两边不一致。
 */
public final class AgentPrefs {

    private static final String FILE = "prism_agent_prefs";
    private static final String K_USER_STOPPED = "user_stopped";
    private static final String K_LAST_BOOT = "last_boot_at";

    private AgentPrefs() {
    }

    private static SharedPreferences sp(Context ctx) {
        return ctx.getApplicationContext()
                .getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /** 用户是否主动停止过服务 */
    public static boolean isUserStopped(Context ctx) {
        return sp(ctx).getBoolean(K_USER_STOPPED, false);
    }

    public static void setUserStopped(Context ctx, boolean stopped) {
        sp(ctx).edit().putBoolean(K_USER_STOPPED, stopped).apply();
    }

    public static long getLastBoot(Context ctx) {
        return sp(ctx).getLong(K_LAST_BOOT, 0L);
    }

    public static void setLastBoot(Context ctx, long ts) {
        sp(ctx).edit().putLong(K_LAST_BOOT, ts).apply();
    }
}

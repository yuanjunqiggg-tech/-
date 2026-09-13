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
 * ★ 2026-09-13 补充：设备凭据现在**也要**在这里存一份。
 *
 * 原因（真机踩出来的）：长轮询原本跑在 WebView 的 JS 里，云手机一锁屏或
 * 切到后台，WebView 的定时器就被系统节流甚至整个冻住，设备立刻假死——
 * 现象就是「控制台显示离线，指令全部超时」。
 *
 * 修法是把轮询挪到原生层（NativePoller 跑在 AgentService 的后台线程），
 * 不依赖 WebView 是否存活。原生层要自己知道 device_id / token / 网关地址 /
 * Prism 端口，所以这里必须存一份。
 *
 * WebView 那边的 localStorage 仍然是「配置 UI 的当前值」，
 * 每次注册/保存都会通过 PrismNative.setCredentials() 同步过来。
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

    // ============================================================
    // 设备凭据（供原生层轮询使用）
    // ============================================================
    private static final String K_DEV_ID = "device_id";
    private static final String K_TOKEN = "device_token";
    private static final String K_ENDPOINT = "endpoint";
    private static final String K_PORT = "prism_port";
    private static final String K_DEV_NAME = "device_name";

    public static void setCredentials(Context ctx, String deviceId, String token,
                                      String endpoint, int port, String name) {
        sp(ctx).edit()
                .putString(K_DEV_ID, deviceId)
                .putString(K_TOKEN, token)
                .putString(K_ENDPOINT, endpoint)
                .putInt(K_PORT, port)
                .putString(K_DEV_NAME, name)
                .apply();
    }

    public static String deviceId(Context ctx) { return sp(ctx).getString(K_DEV_ID, ""); }
    public static String token(Context ctx) { return sp(ctx).getString(K_TOKEN, ""); }
    public static String deviceName(Context ctx) { return sp(ctx).getString(K_DEV_NAME, ""); }

    public static int prismPort(Context ctx) { return sp(ctx).getInt(K_PORT, 8080); }

    /** 网关地址，已去掉结尾斜杠；没配过就返回默认那个 */
    public static String endpoint(Context ctx) {
        String e = sp(ctx).getString(K_ENDPOINT, "");
        if (e == null || e.isEmpty()) e = "https://ai-api.youyuanqi.dpdns.org";
        while (e.endsWith("/")) e = e.substring(0, e.length() - 1);
        return e;
    }

    /** 凭据是否齐全（齐全才能开轮询） */
    public static boolean hasCredentials(Context ctx) {
        String id = sp(ctx).getString(K_DEV_ID, "");
        String tk = sp(ctx).getString(K_TOKEN, "");
        return id != null && !id.isEmpty() && tk != null && !tk.isEmpty();
    }

    public static void clearCredentials(Context ctx) {
        sp(ctx).edit().remove(K_DEV_ID).remove(K_TOKEN).apply();
    }

    // ============================================================
    // 机器人连接守护（BotKeeper）
    // ============================================================
    //
    // 用户要求：AI 如果没进服务器就自动连上；默认一直自动连接；
    // 给一个开关，可以关掉，也可以只跑一次。
    //
    //   off    关闭守护（完全不碰机器人连接）
    //   once   只跑一次：连上一次就自动切回 off
    //   always 一直守护（默认）：掉线就重连
    private static final String K_BOT_KEEPER_MODE = "bot_keeper_mode";
    private static final String K_BOT_KEEPER_INTERVAL = "bot_keeper_interval_sec";

    public static final String BOT_KEEPER_OFF = "off";
    public static final String BOT_KEEPER_ONCE = "once";
    public static final String BOT_KEEPER_ALWAYS = "always";

    /** 守护模式，默认 always（用户明确要求的默认值） */
    public static String botKeeperMode(Context ctx) {
        String m = sp(ctx).getString(K_BOT_KEEPER_MODE, BOT_KEEPER_ALWAYS);
        if (m == null) return BOT_KEEPER_ALWAYS;
        m = m.trim().toLowerCase();
        if (!BOT_KEEPER_OFF.equals(m) && !BOT_KEEPER_ONCE.equals(m) && !BOT_KEEPER_ALWAYS.equals(m)) {
            return BOT_KEEPER_ALWAYS;
        }
        return m;
    }

    public static void setBotKeeperMode(Context ctx, String mode) {
        sp(ctx).edit().putString(K_BOT_KEEPER_MODE, mode).apply();
    }

    /** 探测间隔（秒），默认 15，夹在 5~600 之间 */
    public static int botKeeperIntervalSec(Context ctx) {
        int v = sp(ctx).getInt(K_BOT_KEEPER_INTERVAL, 15);
        if (v < 5) v = 5;
        if (v > 600) v = 600;
        return v;
    }

    public static void setBotKeeperIntervalSec(Context ctx, int sec) {
        sp(ctx).edit().putInt(K_BOT_KEEPER_INTERVAL, sec).apply();
    }
}

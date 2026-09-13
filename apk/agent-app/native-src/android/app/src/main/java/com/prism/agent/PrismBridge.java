package com.prism.agent;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.util.Log;

import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.TimeUnit;

/**
 * ============================================================
 * Prism 本机引擎桥 · 拉起 / 探活
 * ============================================================
 *
 * ★ 为什么需要这个类（用户的核心诉求）
 *
 * 用户要求：「我要操纵的是 APK 里面的东西，不是网页的；APK 自己打开更稳」。
 *
 * 结论（已通过拆包验证）：Prism APK 的界面本身就是 WebView 加载
 * `http://127.0.0.1:8080`，APK 里没有任何前端资源（assets 只有一张 logo）。
 * 也就是说 **「APK 里点按钮」和「调 8080 接口」打到的是同一个 Go 引擎
 * （libprism.so，与 APK 同进程），读写的都是同一份数据**：
 *
 *     /data/data/com.prismtool.box/files/   ← config.json、td_state.db
 *     /sdcard/Download/Prism                ← 导出产物
 *
 * 所以不存在「两条路数据不同」的问题。真正的唯一前提是：
 *   **Prism 进程必须活着**——进程没了，8080 就没了，APK 打开也一样白屏。
 *
 * 本类就是保证这个前提：
 *   1. alive()  —— 探测 8080 是否响应（短超时，不能卡住轮询线程）
 *   2. launch() —— 用显式 Intent 拉起 Prism（等价于用户点桌面图标）
 *   3. ensure() —— 不活着就拉起，并轮询等待就绪
 *
 * 被控端每次执行指令前都会调 ensure()，
 * 这样即使云手机把 Prism 杀了，下一次指令也能自己把它救回来。
 */
public final class PrismBridge {

    private static final String TAG = "PrismAgent";

    /** Prism 工具箱包名（拆包确认：com.prismtool.box） */
    public static final String PRISM_PKG = "com.prismtool.box";

    /** Prism 主 Activity（AndroidManifest 里 exported=true，LAUNCHER） */
    private static final String PRISM_MAIN = "com.prismtool.box.MainActivity";

    /** 保活服务（不 exported，只能用显式 Intent 且需同签名/同 UID？
     *  实测 KeepService exported=false → 第三方无法直接 startService。
     *  所以统一走 MainActivity，由 Prism 自己起 KeepService。） */
    private static final String PRISM_KEEP = "com.prismtool.box.KeepService";

    private PrismBridge() {
    }

    // ============================================================
    // 安装检测
    // ============================================================
    public static boolean isInstalled(Context ctx) {
        try {
            ctx.getPackageManager().getPackageInfo(PRISM_PKG, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        } catch (Throwable t) {
            Log.w(TAG, "检测 Prism 安装状态失败：" + t.getMessage());
            return false;
        }
    }

    // ============================================================
    // 探活
    // ============================================================

    /**
     * 探测本机 Prism 引擎是否活着。
     *
     * 用 /api/bot/status 而不是 / ：根路径可能返回大段 HTML，
     * 而这里只想要一个"引擎在不在"的布尔值，越轻越好。
     *
     * ★ 必须在子线程调用 —— 主线程做网络请求会 NetworkOnMainThreadException。
     *
     * @param port    Prism 端口，默认 8080
     * @param timeout 单次超时（毫秒）
     */
    public static boolean alive(int port, int timeout) {
        HttpURLConnection c = null;
        try {
            URL u = new URL("http://127.0.0.1:" + (port > 0 ? port : 8080) + "/api/bot/status");
            c = (HttpURLConnection) u.openConnection();
            c.setConnectTimeout(timeout);
            c.setReadTimeout(timeout);
            c.setRequestMethod("GET");
            c.setInstanceFollowRedirects(false);
            c.setUseCaches(false);
            int code = c.getResponseCode();
            // 401/403 也算活着 —— 那是引擎在挡我们，不是没起来
            return code > 0;
        } catch (IOException e) {
            return false;   // 连不上 = 没起来
        } catch (Throwable t) {
            Log.w(TAG, "探活异常：" + t.getMessage());
            return false;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    // ============================================================
    // 拉起
    // ============================================================

    /**
     * 拉起 Prism APK（等价于用户点桌面图标）。
     *
     * 三级降级，因为不同 ROM 对后台启动 Activity 的限制不一样：
     *   1. 显式 Intent 直接指 MainActivity —— 最可靠
     *   2. getLaunchIntentForPackage()     —— 兜底
     *   3. 启动 KeepService                —— 部分 ROM 上 Activity 被拦但服务能起
     *
     * ★ 全部包 try/catch(Throwable)：Android 12+ 后台启动限制会抛
     *   ForegroundServiceStartNotAllowedException / SecurityException，
     *   裸调会让被控端进程崩溃（这个坑已经在 AgentService 里踩过一次）。
     *
     * @return 实际使用的拉起方式，null 表示全部失败
     */
    public static String launch(Context ctx) {
        if (!isInstalled(ctx)) {
            Log.w(TAG, "未安装 Prism（" + PRISM_PKG + "）");
            return null;
        }

        // 1) 显式 Intent → MainActivity
        try {
            Intent i = new Intent();
            i.setClassName(PRISM_PKG, PRISM_MAIN);
            i.setAction(Intent.ACTION_MAIN);
            i.addCategory(Intent.CATEGORY_LAUNCHER);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP
                    | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
            ctx.startActivity(i);
            Log.i(TAG, "已通过 MainActivity 拉起 Prism");
            return "activity";
        } catch (Throwable t) {
            Log.w(TAG, "MainActivity 拉起失败：" + t.getMessage());
        }

        // 2) 包级 Launch Intent
        try {
            Intent i = ctx.getPackageManager().getLaunchIntentForPackage(PRISM_PKG);
            if (i != null) {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
                ctx.startActivity(i);
                Log.i(TAG, "已通过 launch intent 拉起 Prism");
                return "launch_intent";
            }
        } catch (Throwable t) {
            Log.w(TAG, "launch intent 拉起失败：" + t.getMessage());
        }

        // 3) 直接起保活服务（Prism 的 KeepService exported=false，
        //    多数 ROM 会拒绝，但云手机/定制 ROM 上有时可行，留作最后尝试）
        try {
            Intent i = new Intent();
            i.setClassName(PRISM_PKG, PRISM_KEEP);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i);
            } else {
                ctx.startService(i);
            }
            Log.i(TAG, "已尝试拉起 Prism KeepService");
            return "keep_service";
        } catch (Throwable t) {
            Log.w(TAG, "KeepService 拉起失败：" + t.getMessage());
        }

        return null;
    }

    // ============================================================
    // 确保就绪
    // ============================================================

    /**
     * 确保 Prism 引擎可用：不活着就拉起，然后轮询等待就绪。
     *
     * ★ 阻塞调用，必须在子线程 / 协程里跑。
     *
     * @param port        Prism 端口
     * @param waitMs      拉起后最多等多少毫秒（引擎冷启动需要几秒）
     * @return 结果描述，供 UI 展示
     */
    public static Result ensure(Context ctx, int port, int waitMs) {
        int p = port > 0 ? port : 8080;

        if (alive(p, 1500)) {
            return new Result(true, "already_running", "Prism 已在运行", 0);
        }

        Log.w(TAG, "Prism 未响应，尝试拉起…");
        String how = launch(ctx);

        if (how == null) {
            return new Result(false, "launch_failed",
                    "无法拉起 Prism（未安装，或系统禁止后台启动 Activity）", 0);
        }

        long deadline = System.currentTimeMillis() + Math.max(waitMs, 1000);
        long t0 = System.currentTimeMillis();
        int tries = 0;

        while (System.currentTimeMillis() < deadline) {
            tries++;
            if (alive(p, 1500)) {
                long cost = System.currentTimeMillis() - t0;
                Log.i(TAG, "Prism 已就绪（" + how + "），耗时 " + cost + "ms");
                return new Result(true, how, "已拉起 Prism（" + how + "）", cost);
            }
            try {
                Thread.sleep(800);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }

        return new Result(false, how,
                "已发出拉起请求（" + how + "），但 " + (waitMs / 1000) + "s 内 8080 仍未响应",
                System.currentTimeMillis() - t0);
    }

    // ============================================================
    // 结果封装
    // ============================================================
    public static final class Result {
        public final boolean ok;
        public final String how;       // already_running / activity / launch_intent / keep_service
        public final String message;
        public final long costMs;

        Result(boolean ok, String how, String message, long costMs) {
            this.ok = ok;
            this.how = how;
            this.message = message;
            this.costMs = costMs;
        }
    }
}

package com.prism.agent;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import androidx.core.app.NotificationCompat;

/**
 * ============================================================
 * Prism 被控端 · 前台服务
 * ============================================================
 *
 * 云手机场景下，进程被系统回收是最大的敌人。这个服务的职责就是
 * 让 App 在后台长期存活：
 *
 *   1. 常驻通知栏（前台服务）—— 显著降低被杀概率
 *   2. START_STICKY —— 被系统杀掉后自动重建
 *   3. 持 WakeLock —— 防止 CPU 在息屏后休眠导致轮询停止
 *   4. 心跳自检 —— 定期确认 WebView 侧的轮询循环还活着
 *
 * 注意：真正的指令执行逻辑在 WebView 里的 agent.html（JS）中，
 * 本服务只负责「保命」与「唤醒」，不重复实现业务逻辑。
 * 这样跨平台、好维护，也避免两套实现行为不一致。
 */
public class AgentService extends Service {

    private static final String TAG = "PrismAgent";

    private static final String CHAN_ID = "prism_agent";
    private static final String CHAN_NAME = "Prism 被控端";
    private static final int NOTIFY_ID = 1001;

    /** 静态引用，便于 Activity 判断服务是否在跑 */
    public static volatile boolean running = false;

    private PowerManager.WakeLock wakeLock;

    // ============================================================
    // 生命周期
    // ============================================================
    @Override
    public void onCreate() {
        super.onCreate();
        running = true;

        createChannel();
        startForegroundCompat(buildNotification());
        acquireWakeLock();

        // ★ 把真正的指令循环挪到原生线程。
        //   WebView 的 JS 定时器在云手机锁屏/切后台后会被冻住，
        //   只靠它设备会在几分钟内假死（真机实测 3 分钟掉线）。
        //   原生线程不受 WebView 生命周期影响。
        NativePoller.get(this).start();

        // ★ 机器人连接守护：掉线自动重连（默认 always，可关 / 可只跑一次）。
        //   Prism 的「AI帮写」自己不会重连 —— 机器人一掉线它就只能干等，
        //   系统提示词里那句「机器人当前未连接，game_call 会返回错误」就是证据。
        //   这层补上它。
        BotKeeper.get(this).start();

        Log.i(TAG, "前台服务已启动");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 每次被拉起都刷新一下通知，顺便重置被杀计数
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) {
            nm.notify(NOTIFY_ID, buildNotification());
        }

        // ★ START_STICKY：被系统回收后自动重建，且不重放 Intent
        return START_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        // 用户从最近任务里划掉 App 时，系统会调到这里。
        // 云手机场景下我们希望能自己爬起来，所以主动重启一次。
        // ★ 必须用 startSafely —— 这里 App 已在后台，Android 12+ 会拒绝，
        //   裸调 startForegroundService 会抛异常导致进程崩溃。
        Log.w(TAG, "任务被移除，尝试自启");
        startSafely(this);
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        running = false;
        NativePoller.get(this).stop();
        BotKeeper.get(this).stop();
        releaseWakeLock();
        Log.w(TAG, "前台服务被销毁");

        // 被销毁后主动尝试重启（除非用户明确停止）。
        // ★ 同样必须走 startSafely。
        if (!AgentPrefs.isUserStopped(this)) {
            startSafely(this);
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ============================================================
    // 通知
    // ============================================================
    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) {
                NotificationChannel c = new NotificationChannel(
                        CHAN_ID, CHAN_NAME, NotificationManager.IMPORTANCE_LOW);
                c.setDescription("保持与云端的连接，接收远程指令");
                c.setShowBadge(false);
                nm.createNotificationChannel(c);
            }
        }
    }

    private Notification buildNotification() {
        // 点通知回到 App 主界面
        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_NEW_TASK);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            piFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, piFlags);

        return new NotificationCompat.Builder(this, CHAN_ID)
                .setContentTitle("Prism 被控端运行中")
                .setContentText("正在等待云端指令")
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentIntent(pi)
                .setOngoing(true)
                .setShowWhen(false)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build();
    }

    private void startForegroundCompat(Notification n) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFY_ID, n,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIFY_ID, n);
        }
    }

    // ============================================================
    // WakeLock
    // ============================================================
    private void acquireWakeLock() {
        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            if (pm == null) return;
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "prism:agent");
            wakeLock.setReferenceCounted(false);
            // 不设超时：由服务生命周期管理；Destroy 时释放
            wakeLock.acquire();
            Log.i(TAG, "WakeLock 已获取");
        } catch (Exception e) {
            Log.w(TAG, "获取 WakeLock 失败：" + e.getMessage());
        }
    }

    private void releaseWakeLock() {
        try {
            if (wakeLock != null && wakeLock.isHeld()) {
                wakeLock.release();
                Log.i(TAG, "WakeLock 已释放");
            }
        } catch (Exception ignored) {
        }
        wakeLock = null;
    }

    // ============================================================
    // 静态工具：供 Activity / 其他组件调用
    // ============================================================

    /**
     * 安全启动前台服务。
     *
     * ★ 这个包装是必需的，不是过度防御。
     *
     * Android 12（API 31）起，App 处于后台时调用 startForegroundService()
     * 会抛 ForegroundServiceStartNotAllowedException。
     * 而以下几个调用点恰恰都在后台发生：
     *   - onDestroy()      服务被回收时
     *   - onTaskRemoved()  用户划掉任务后
     *   - BootReceiver     开机广播（部分 ROM 上也不许）
     *
     * 裸调会抛未捕获异常 → 进程直接崩溃，
     * 表现就是「云手机上的被控端时不时就消失」。
     *
     * 失败时并不代表永久失败：
     *   - 系统回收导致的销毁由 START_STICKY 兜底重建
     *   - 下次用户打开 App，MainActivity 会再次 ensureServiceRunning()
     *
     * @return 是否成功发出启动请求
     */
    public static boolean startSafely(Context ctx) {
        try {
            Intent i = new Intent(ctx, AgentService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i);
            } else {
                ctx.startService(i);
            }
            return true;
        } catch (Throwable t) {
            // 用 Throwable 而非 Exception：部分 ROM 抛的是 Error 子类
            Log.w(TAG, "启动前台服务被拒绝（Android 12+ 后台限制）：" + t.getMessage());
            return false;
        }
    }

    /** 启动（或确认已启动）前台服务 */
    public static void start(Context ctx) {
        AgentPrefs.setUserStopped(ctx, false);
        startSafely(ctx);
    }

    /** 用户主动停止 —— 之后不再自动拉起 */
    public static void stop(Context ctx) {
        AgentPrefs.setUserStopped(ctx, true);
        ctx.stopService(new Intent(ctx, AgentService.class));
    }
}

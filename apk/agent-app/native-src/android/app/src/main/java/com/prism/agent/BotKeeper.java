package com.prism.agent;

import android.content.Context;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * ============================================================
 * 机器人连接守护 · BotKeeper
 * ============================================================
 *
 * ★ 为什么需要它（用户明确提出的需求）
 *
 * Prism 内置的「AI帮写」有个短板：机器人一掉线，它就废了一半。
 * 它的系统提示词里会动态写进一句
 *     「机器人当前未连接，game_call 工具会返回错误，不要依赖它。」
 * —— 也就是说 AI帮写 **知道** 自己连不上服务器，但它**什么都不做**，
 * 只能干等用户手动去 Prism 界面里点「连接」。
 *
 * 结果是：AI 越用越哑。用户要的是：
 *   · 机器人没进服务器 → 自动连上
 *   · 默认一直自动连接（掉线就重连）
 *   · 给一个开关，可以关掉
 *   · 也可以设成「只运行一次」
 *
 * 这个类就干这一件事。它是我们这层（被控端）独有的能力 ——
 * 不依赖 Prism 内部实现，也不需要它配合。
 *
 * ------------------------------------------------------------
 * 三种模式
 * ------------------------------------------------------------
 *   off     关闭：只探测、不重连
 *   once    只运行一次：连上一次就自动切回 off
 *   always  一直守护（默认）：掉线就重连
 *
 * ------------------------------------------------------------
 * 怎么连（参数从哪来）
 * ------------------------------------------------------------
 * 全部来自 Prism 自己的 GET /api/config，不需要用户再填一遍：
 *   token            机器人 token（形如 adb//....）
 *   server_code      服务器编号
 *   auth_url         认证服务器地址 → 对应 connect 的 auth 字段
 *   use_new_protocol 是否走新协议
 *   server_pass      服务器密码（一般空）
 *
 * 然后 POST /api/bot/connect
 *   {token, server, use_new_protocol, auth, password}
 *
 * 这个报文格式是从 Prism 前端 JS 里挖出来的（doConn() 函数），
 * 不是猜的。
 *
 * ------------------------------------------------------------
 * ★ 为什么即使在 off 模式也继续探测
 * ------------------------------------------------------------
 * 探测是只读的（GET /api/bot/status），成本极低（本机 127.0.0.1）。
 * 但拿到的最新状态会让心跳里的 bot_connected / bot_server 变准 ——
 * 现在控制台的「机器人」一栏一直显示未连接，就是因为没人上报。
 * 所以 off 只关掉「重连」这个动作，不关探测。
 *
 * ------------------------------------------------------------
 * 节流
 * ------------------------------------------------------------
 * 探测间隔默认 15 秒（可配 5~600）。
 * 连接失败会指数退避（15→30→60→120 秒封顶），
 * 避免服务器挂了的时候每 15 秒锤一次、把账号锤进风控。
 */
public final class BotKeeper {

    private static final String TAG = "PrismAgent";

    private static volatile BotKeeper instance;

    private final Context appCtx;
    private final AtomicBoolean running = new AtomicBoolean(false);
    private Thread worker;

    // ---- 对外可读的状态快照（心跳与状态查询都读它，避免重复探测） ----
    private volatile boolean connected = false;
    private volatile String server = "";
    private volatile String dimension = "";
    private volatile boolean isOp = false;
    private volatile long lastProbeAt = 0;
    private volatile long lastConnectedAt = 0;
    private volatile long lastAttemptAt = 0;
    private volatile long lastOkConnectAt = 0;  // 上次成功「发起」连接的时间（握手宽限期起点）
    private volatile String lastMessage = "";
    private volatile int attempts = 0;        // 累计发起连接的次数
    private volatile int failStreak = 0;      // 连续失败次数

    /**
     * 「只运行一次」模式下的最大尝试次数。
     * ★ 为什么要有上限：once 的语义是「帮我连一次就行」，不是「换个名字继续常驻重连」。
     *   没有上限的话，服务器一直连不上时 once 和 always 行为完全一样，开关就白给了。
     */
    private static final int ONCE_MAX_ATTEMPTS = 3;

    /**
     * 成功「发起」连接后，给它多久去完成握手。
     *
     * ★ 为什么需要：POST /api/bot/connect 返回 ok 只代表「请求被接受」，
     *   不代表已经连上 —— 之后还要等服务器授权，可能几十秒。
     *   Prism 自己的前端也是连上后一直轮询 /api/bot/status 等 connected 变 true，
     *   而且明确注释「不再设强制超时」。
     *   没有这个宽限期的话，探测发现 connected 还是 false，就会 15 秒重发一次 connect，
     *   把正在进行的握手打断 —— 越连越连不上。
     */
    private static final long CONNECT_GRACE_MS = 60_000L;

    private BotKeeper(Context ctx) {
        this.appCtx = ctx.getApplicationContext();
    }

    public static BotKeeper get(Context ctx) {
        if (instance == null) {
            synchronized (BotKeeper.class) {
                if (instance == null) instance = new BotKeeper(ctx);
            }
        }
        return instance;
    }

    public boolean isRunning() {
        return running.get();
    }

    // ---- 给心跳/状态查询用的只读快照 ----
    public boolean isConnected() { return connected; }
    public String serverCode() { return server; }

    /** 状态快照，直接塞进心跳或指令返回值 */
    public JSONObject snapshot() {
        JSONObject o = new JSONObject();
        try {
            o.put("mode", AgentPrefs.botKeeperMode(appCtx));
            o.put("interval_sec", AgentPrefs.botKeeperIntervalSec(appCtx));
            o.put("running", running.get());
            o.put("connected", connected);
            o.put("server", server);
            o.put("dimension", dimension);
            o.put("is_op", isOp);
            o.put("probed_at", lastProbeAt);
            o.put("connected_at", lastConnectedAt);
            o.put("attempted_at", lastAttemptAt);
            o.put("attempts", attempts);
            o.put("fail_streak", failStreak);
            // 已发起连接、正在等服务器授权（这期间不会重发，避免打断握手）
            o.put("handshaking",
                    System.currentTimeMillis() - lastOkConnectAt < CONNECT_GRACE_MS);
            o.put("message", lastMessage);
        } catch (Exception ignored) {
        }
        return o;
    }

    // ============================================================
    // 起停
    // ============================================================
    public synchronized void start() {
        if (running.get()) return;
        running.set(true);
        worker = new Thread(this::loop, "prism-bot-keeper");
        worker.setDaemon(true);
        worker.start();
        Log.i(TAG, "机器人守护已启动，模式=" + AgentPrefs.botKeeperMode(appCtx));
    }

    public synchronized void stop() {
        running.set(false);
        if (worker != null) worker.interrupt();
        worker = null;
        Log.i(TAG, "机器人守护已停止");
    }

    /** 改模式：持久化 + 立即生效（always/once 需要线程在跑） */
    public synchronized JSONObject setMode(String mode) {
        String m = (mode == null ? "" : mode.trim().toLowerCase());
        if (!AgentPrefs.BOT_KEEPER_OFF.equals(m)
                && !AgentPrefs.BOT_KEEPER_ONCE.equals(m)
                && !AgentPrefs.BOT_KEEPER_ALWAYS.equals(m)) {
            JSONObject e = new JSONObject();
            try {
                e.put("ok", false);
                e.put("error", "mode 只能是 off / once / always");
            } catch (Exception ignored) {
            }
            return e;
        }
        AgentPrefs.setBotKeeperMode(appCtx, m);
        failStreak = 0;
        if (AgentPrefs.BOT_KEEPER_OFF.equals(m)) {
            lastMessage = "守护已关闭（仍会探测，但不重连）";
        } else if (AgentPrefs.BOT_KEEPER_ONCE.equals(m)) {
            lastMessage = "只运行一次：连上后自动关闭守护";
            start();
        } else {
            lastMessage = "一直守护：掉线自动重连";
            start();
        }
        Log.i(TAG, "机器人守护模式切换为 " + m);
        return snapshot();
    }

    public JSONObject setIntervalSec(int sec) {
        AgentPrefs.setBotKeeperIntervalSec(appCtx, sec);
        return snapshot();
    }

    /** 立即探测一次（用户点「立即检查」或 MCP 调用时用） */
    public JSONObject probeNow() {
        try {
            probe();
        } catch (Throwable t) {
            lastMessage = "探测失败：" + t.getMessage();
        }
        return snapshot();
    }

    /** 立即尝试连接一次（不管模式） */
    public JSONObject connectNow() {
        try {
            probe();
            if (!connected) doConnect();
        } catch (Throwable t) {
            lastMessage = "连接失败：" + t.getMessage();
        }
        return snapshot();
    }

    // ============================================================
    // 主循环
    // ============================================================
    private void loop() {
        while (running.get()) {
            try {
                probe();

                String mode = AgentPrefs.botKeeperMode(appCtx);

                // 失败退避：连续失败就拉长间隔，最多 120 秒
                long waitMs = Math.min(15_000L << Math.min(failStreak, 3), 120_000L);
                boolean due = System.currentTimeMillis() - lastAttemptAt >= waitMs;

                // ★ 握手宽限期：刚成功发起过连接，就安静等它连上，别重发打断
                boolean handshaking =
                        System.currentTimeMillis() - lastOkConnectAt < CONNECT_GRACE_MS;

                if (AgentPrefs.BOT_KEEPER_ALWAYS.equals(mode) && !connected && due && !handshaking) {
                    doConnect();
                }

                // once：连上了就功成身退
                if (AgentPrefs.BOT_KEEPER_ONCE.equals(mode)) {
                    if (connected) {
                        AgentPrefs.setBotKeeperMode(appCtx, AgentPrefs.BOT_KEEPER_OFF);
                        lastMessage = "已连接，守护自动关闭（只运行一次）";
                        Log.i(TAG, lastMessage);
                        break;
                    }
                    if (handshaking) {
                        // 正在握手，不消耗尝试次数
                    } else if (failStreak < ONCE_MAX_ATTEMPTS && due) {
                        doConnect();
                    } else if (failStreak >= ONCE_MAX_ATTEMPTS) {
                        // ★ 不能无限重试：只运行一次 ≠ 一直在后台重连，
                        //   试够次数就认输并关掉守护，否则这个开关等于没关。
                        AgentPrefs.setBotKeeperMode(appCtx, AgentPrefs.BOT_KEEPER_OFF);
                        lastMessage = "只运行一次：连续 " + failStreak + " 次未连上，守护已自动关闭";
                        Log.w(TAG, lastMessage);
                        break;
                    }
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            } catch (Throwable t) {
                // ★ catch Throwable：部分 ROM 抛 Error 子类，漏了会让线程静默死掉
                Log.w(TAG, "机器人守护异常：" + t.getMessage());
            }
            sleepQuiet(AgentPrefs.botKeeperIntervalSec(appCtx) * 1000L);
        }
        running.set(false);
        Log.w(TAG, "机器人守护线程退出");
    }

    private void sleepQuiet(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    // ============================================================
    // 探测 / 连接
    // ============================================================
    private void probe() throws Exception {
        JSONObject st = prismGet("/api/bot/status");
        lastProbeAt = System.currentTimeMillis();
        boolean wasConnected = connected;
        connected = st != null && st.optBoolean("connected", false);
        if (st != null) {
            server = st.optString("server", server);
            dimension = st.optString("dimension", "");
            isOp = st.optBoolean("is_op", false);
        }
        if (connected) {
            if (!wasConnected) lastConnectedAt = lastProbeAt;
            failStreak = 0;
            if (lastMessage.isEmpty() || lastMessage.startsWith("连接失败")) {
                lastMessage = "机器人在线（" + server + "）";
            }
        } else if (!wasConnected) {
            lastMessage = "机器人未连接";
        }
    }

    /**
     * 从 Prism 自己的配置里取连接参数并发起连接。
     * 参数不用用户填 —— Prism 里连过一次就一直在 /api/config 里。
     */
    private void doConnect() {
        lastAttemptAt = System.currentTimeMillis();
        attempts++;
        try {
            JSONObject cfgRoot = prismGet("/api/config");
            JSONObject cfg = cfgRoot == null ? null : cfgRoot.optJSONObject("config");
            if (cfg == null) {
                failStreak++;
                lastMessage = "读不到 /api/config，无法自动连接";
                Log.w(TAG, lastMessage);
                return;
            }

            String token = cfg.optString("token", "");
            String serverCode = cfg.optString("server_code", "");
            if (token.isEmpty() || serverCode.isEmpty()) {
                failStreak++;
                lastMessage = "配置里没有 token / 服务器号，请在 Prism 里先手动连一次";
                Log.w(TAG, lastMessage);
                return;
            }

            JSONObject body = new JSONObject();
            body.put("token", token);
            body.put("server", serverCode);
            body.put("use_new_protocol", cfg.optBoolean("use_new_protocol", false));
            // 前端 doConn() 里 auth 就是当前选中的服务器地址（= 配置里的 auth_url）
            body.put("auth", cfg.optString("auth_url", ""));
            body.put("password", cfg.optString("server_pass", ""));

            JSONObject r = prismPost("/api/bot/connect", body, "POST");
            boolean ok = r != null && r.optBoolean("ok", false);
            if (ok) {
                failStreak = 0;
                lastOkConnectAt = System.currentTimeMillis();
                lastMessage = "已发起连接（服务器 " + serverCode + "），等待握手";
                Log.i(TAG, lastMessage);
            } else {
                failStreak++;
                lastMessage = "连接被拒：" + (r == null ? "无响应" : r.toString());
                Log.w(TAG, lastMessage);
            }
        } catch (Throwable t) {
            failStreak++;
            lastMessage = "连接异常：" + t.getMessage();
            Log.w(TAG, lastMessage);
        }
    }

    // ============================================================
    // 本机 Prism HTTP（127.0.0.1）
    // ============================================================
    private JSONObject prismGet(String path) throws Exception {
        return prismPost(path, null, "GET");
    }

    private JSONObject prismPost(String path, JSONObject body, String method) throws Exception {
        int port = AgentPrefs.prismPort(appCtx);
        HttpURLConnection c = (HttpURLConnection) new URL(
                "http://127.0.0.1:" + port + path).openConnection();
        try {
            c.setRequestMethod(method);
            c.setRequestProperty("Content-Type", "application/json");
            c.setConnectTimeout(4000);
            c.setReadTimeout(15_000);
            if (body != null && !"GET".equals(method)) {
                c.setDoOutput(true);
                OutputStream os = c.getOutputStream();
                os.write(body.toString().getBytes(StandardCharsets.UTF_8));
                os.close();
            }
            int code = c.getResponseCode();
            InputStream is = (code >= 400) ? c.getErrorStream() : c.getInputStream();
            String s = is == null ? "" : readAll(is);
            if (s.trim().isEmpty()) return new JSONObject().put("ok", code < 400).put("status", code);
            try {
                return new JSONObject(s);
            } catch (Exception e) {
                return new JSONObject().put("ok", code < 400).put("raw", s);
            }
        } finally {
            c.disconnect();
        }
    }

    private static String readAll(InputStream is) throws Exception {
        StringBuilder sb = new StringBuilder();
        char[] buf = new char[4096];
        BufferedReader br = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8));
        int n;
        while ((n = br.read(buf)) > 0) sb.append(buf, 0, n);
        br.close();
        return sb.toString();
    }
}

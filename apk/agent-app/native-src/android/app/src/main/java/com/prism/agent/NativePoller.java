package com.prism.agent;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * ============================================================
 * 原生长轮询 · 被控端的主循环
 * ============================================================
 *
 * ★ 为什么要有这个类（真机踩出来的坑，不是过度设计）
 *
 * 之前整个被控端逻辑跑在 WebView 的 JS 里：一个 while 循环调
 * /device/poll，领到指令就去打 127.0.0.1:8080。
 *
 * 真机上的表现：云手机锁屏、或者切到别的 App 之后，
 * **WebView 的 JS 定时器会被系统节流乃至整个冻住** ——
 * 前台服务还活着（通知栏还在），但循环停了。
 * 现象就是「控制台显示离线，下发指令全部超时」。
 * 实测设备上线 3 分钟后就掉线，正好对得上这个。
 *
 * 修法：把这条循环搬到原生线程里。Service 的后台线程不受
 * WebView 生命周期影响，系统冻 WebView 也不会冻它。
 *
 * 职责（和 JS 版一一对应，行为保持一致）：
 *   1. /device/poll       领指令
 *   2. 按 kind 执行：chat / tool / prism_rest / session_* / prism_status
 *   3. /device/report     回传结果与事件
 *   4. 顺带每 20s 发一次心跳
 *
 * ★ 与 JS 版的关系：两边都在跑也没关系。
 *   指令的领取在服务端是原子的（UPDATE ... WHERE status='pending'），
 *   谁先领到算谁的，不会重复执行。
 */
public final class NativePoller {

    private static final String TAG = "PrismAgent";

    /** 单例，Service 与 Activity 共用一条循环 */
    private static volatile NativePoller instance;

    private final Context appCtx;
    private final AtomicBoolean running = new AtomicBoolean(false);
    private Thread worker;

    private long lastHeartbeat = 0;

    private NativePoller(Context ctx) {
        this.appCtx = ctx.getApplicationContext();
    }

    public static NativePoller get(Context ctx) {
        if (instance == null) {
            synchronized (NativePoller.class) {
                if (instance == null) instance = new NativePoller(ctx);
            }
        }
        return instance;
    }

    public boolean isRunning() {
        return running.get();
    }

    /** 启动（已在跑则忽略） */
    public synchronized void start() {
        if (running.get()) return;
        if (!AgentPrefs.hasCredentials(appCtx)) {
            Log.w(TAG, "没有设备凭据，轮询不启动（先在界面里绑定设备）");
            return;
        }
        running.set(true);
        worker = new Thread(this::loop, "prism-native-poll");
        worker.setDaemon(true);
        worker.start();
        Log.i(TAG, "原生轮询已启动");
    }

    public synchronized void stop() {
        running.set(false);
        if (worker != null) worker.interrupt();
        worker = null;
        Log.i(TAG, "原生轮询已停止");
    }

    // ============================================================
    // 主循环
    // ============================================================
    private void loop() {
        int idleErrors = 0;
        while (running.get()) {
            try {
                heartbeatIfNeeded();

                JSONObject cmd = poll();
                if (cmd != null && running.get()) {
                    handle(cmd);
                    idleErrors = 0;
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            } catch (Throwable t) {
                // ★ catch Throwable：ROM 可能抛 Error 子类，漏了会让线程静默死掉
                Log.w(TAG, "轮询异常：" + t.getMessage());
                idleErrors++;
                // 连续出错就指数退避，避免死循环刷爆 CPU 和 D1
                sleepQuiet(1000L * Math.min(idleErrors, 30));
            }
        }
        running.set(false);
        Log.w(TAG, "原生轮询线程退出");
    }

    private void sleepQuiet(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    // ============================================================
    // 心跳
    // ============================================================
    private void heartbeatIfNeeded() {
        long now = System.currentTimeMillis();
        if (now - lastHeartbeat < 20_000) return;
        lastHeartbeat = now;
        try {
            JSONObject body = new JSONObject();
            body.put("prism_online", PrismBridge.alive(AgentPrefs.prismPort(appCtx), 1500));
            body.put("battery", -1);
            post("/api/v1/device/heartbeat", body);
        } catch (Throwable t) {
            Log.w(TAG, "心跳失败：" + t.getMessage());
        }
    }

    // ============================================================
    // 领指令
    // ============================================================
    private JSONObject poll() throws Exception {
        JSONObject body = new JSONObject();
        body.put("wait", 25);
        JSONObject r = post("/api/v1/device/poll", body);
        JSONObject data = r.optJSONObject("data");
        if (data == null) return null;
        // ★ 服务端返回的是 data.command（单个对象），不是 commands 数组
        return data.optJSONObject("command");
    }

    // ============================================================
    // 分发执行
    // ============================================================
    private void handle(JSONObject cmd) {
        String id = cmd.optString("id");
        String kind = cmd.optString("kind");
        JSONObject payload = cmd.optJSONObject("payload");
        if (payload == null) payload = new JSONObject();

        Log.i(TAG, "领到指令 " + id + " [" + kind + "]");

        // ★ 和 JS 版一致：执行任何指令前先确保 Prism 活着
        String downMsg = null;
        if (!payload.optBoolean("skip_prism_check")) {
            PrismBridge.Result pr = PrismBridge.ensure(appCtx, AgentPrefs.prismPort(appCtx), 25_000);
            if (!pr.ok) downMsg = "Prism 未运行且无法自动拉起：" + pr.message;
        }

        Object result = null;
        String error = downMsg;

        if (error == null) {
            try {
                switch (kind) {
                    case "chat":
                        result = doChat(payload);
                        break;
                    case "tool":
                        result = doTool(payload);
                        break;
                    case "prism_rest": {
                        // ★ 支持任意方法 + body。
                        //   这是「外部 AI 直接操作 Prism」的主通道 ——
                        //   Prism 的绝大多数能力是 POST 的
                        //   （bot/console、bot/connect、plugin/run、
                        //     mcfunction/execute、task/start、draw/* …），
                        //   只做 GET 就等于只能读不能动。
                        String m = payload.optString("method", "GET").toUpperCase();
                        JSONObject b = payload.optJSONObject("body");
                        if (b == null && payload.has("body") && payload.opt("body") instanceof String) {
                            // 允许调用方直接塞 JSON 字符串
                            try { b = new JSONObject(payload.optString("body")); } catch (Exception ignored) {}
                        }
                        result = prismPost(payload.optString("path", "/api/bot/status"), b, m);
                        break;
                    }
                    case "session_list":
                        result = prismGet("/api/ai/sessions?plugin_id="
                                + enc(payload.optString("plugin_id")));
                        break;
                    case "session_load":
                        result = prismPost("/api/ai/sessions/load",
                                new JSONObject().put("name", payload.optString("session_name")), "POST");
                        break;
                    case "session_save":
                        result = prismPost("/api/ai/sessions", new JSONObject()
                                .put("name", payload.optString("session_name"))
                                .put("plugin_id", payload.optString("plugin_id"))
                                .put("messages", payload.optJSONArray("messages")), "POST");
                        break;
                    case "session_delete":
                        result = prismPost("/api/ai/sessions",
                                new JSONObject().put("name", payload.optString("session_name")), "DELETE");
                        break;
                    case "prism_status":
                        result = new JSONObject()
                                .put("port", AgentPrefs.prismPort(appCtx))
                                .put("native", new JSONObject()
                                        .put("installed", PrismBridge.isInstalled(appCtx))
                                        .put("alive", PrismBridge.alive(AgentPrefs.prismPort(appCtx), 1500)))
                                .put("bot", prismGet("/api/bot/status"));
                        break;
                    case "packet_send":
                        result = doTool(new JSONObject()
                                .put("tool_name", "send_packet")
                                .put("arguments", new JSONObject()
                                        .put("type", payload.optString("packet_type"))
                                        .put("data", payload.optJSONObject("data"))));
                        break;
                    default:
                        error = "未知指令类型：" + kind;
                }
            } catch (Throwable t) {
                error = t.getMessage();
            }
        }

        report(id, cmd.optString("session_id"), result, error);
    }

    // ============================================================
    // chat / tool —— 走 Prism 的 /api/ai/chat SSE
    // ============================================================
    private JSONObject doChat(JSONObject p) throws Exception {
        String msg = p.optString("message");
        if (msg.isEmpty()) msg = p.optString("prompt");

        JSONArray messages = p.optJSONArray("messages");
        if (messages == null || messages.length() == 0) {
            messages = new JSONArray();
            messages.put(new JSONObject().put("role", "user").put("content", msg));
        }

        JSONObject ai = aiChat(p.optString("session_name"), messages);
        String text = ai.optString("text", "");

        // ★ 落盘到 Prism 自己的会话库，这样在 APK 里打开 AI帮写 也能看到
        String sname = p.optString("session_name");
        boolean saved = false;
        if (!sname.isEmpty() && !text.isEmpty()) {
            try {
                messages.put(new JSONObject().put("role", "assistant").put("content", text));
                prismPost("/api/ai/sessions", new JSONObject()
                        .put("name", sname)
                        .put("plugin_id", p.optString("plugin_id"))
                        .put("messages", messages), "POST");
                saved = true;
            } catch (Throwable t) {
                Log.w(TAG, "会话落盘失败：" + t.getMessage());
            }
        }

        return new JSONObject()
                .put("text", text)
                .put("tools", ai.optJSONArray("tools"))
                .put("session_name", sname)
                .put("persisted", saved);
    }

    private JSONObject doTool(JSONObject p) throws Exception {
        String tn = p.optString("tool_name");
        if (tn.isEmpty()) throw new Exception("tool 指令缺少 tool_name");

        JSONArray messages = new JSONArray();
        messages.put(new JSONObject().put("role", "system").put("content",
                "你是工具执行器。用户会指定一个工具名和参数，"
                        + "你必须立即发起该工具的 tool_calls，不要解释、不要闲聊、不要修改参数。"
                        + "只调用这一个工具，然后简短说明结果。"));
        messages.put(new JSONObject().put("role", "user").put("content",
                "请立即调用工具 `" + tn + "`，参数如下（JSON）：\n"
                        + p.optJSONObject("arguments") + "\n\n只调用这一个工具。"));

        JSONObject ai = aiChat(p.optString("session_name"), messages);
        JSONArray tools = ai.optJSONArray("tools");
        JSONObject last = (tools != null && tools.length() > 0)
                ? tools.optJSONObject(tools.length() - 1) : null;

        Object parsed = null;
        if (last != null) parsed = last.opt("result");

        return new JSONObject()
                .put("ok", last != null && !last.optBoolean("is_error"))
                .put("tool", last != null ? last.optString("name") : tn)
                .put("executed", last != null && "executed".equals(last.optString("evidence")))
                .put("result", parsed)
                .put("ai_comment", ai.optString("text", ""));
    }

    /**
     * 调本机 Prism 的 SSE 接口，聚合成 {text, tools}
     *
     * ★ 用 BufferedReader 逐行读，不能用 read(char[]) 死等凑满——
     *   SSE 是长连接，没数据时会一直挂着。
     */
    private JSONObject aiChat(String sessionName, JSONArray messages) throws Exception {
        int port = AgentPrefs.prismPort(appCtx);
        JSONObject body = new JSONObject()
                .put("model_name", "prism自动")
                .put("plugin_id", "")
                .put("mode", "")
                .put("session_name", sessionName == null || sessionName.isEmpty()
                        ? "dev-" + System.currentTimeMillis() : sessionName)
                .put("messages", messages);

        HttpURLConnection c = (HttpURLConnection) new URL(
                "http://127.0.0.1:" + port + "/api/ai/chat").openConnection();
        try {
            c.setRequestMethod("POST");
            c.setRequestProperty("Content-Type", "application/json");
            c.setConnectTimeout(5000);
            c.setReadTimeout(120_000);
            c.setDoOutput(true);
            OutputStream os = c.getOutputStream();
            os.write(body.toString().getBytes(StandardCharsets.UTF_8));
            os.close();

            int code = c.getResponseCode();
            if (code >= 400) throw new Exception("Prism 返回 HTTP " + code);

            StringBuilder text = new StringBuilder();
            JSONArray tools = new JSONArray();

            BufferedReader br = new BufferedReader(new InputStreamReader(
                    c.getInputStream(), StandardCharsets.UTF_8));
            String line;
            String event = null;
            while ((line = br.readLine()) != null) {
                if (line.isEmpty()) { event = null; continue; }
                if (line.startsWith("event:")) { event = line.substring(6).trim(); continue; }
                if (!line.startsWith("data:")) continue;
                String d = line.substring(5).trim();
                JSONObject j;
                try { j = new JSONObject(d); } catch (Exception e) { continue; }

                if ("ai_chunk".equals(event)) {
                    text.append(j.optString("text", ""));
                } else if ("ai_tool_done".equals(event) || "ai_tool_result".equals(event)) {
                    tools.put(j);
                }
            }
            br.close();

            return new JSONObject().put("text", text.toString()).put("tools", tools);
        } finally {
            c.disconnect();
        }
    }

    // ============================================================
    // 本机 Prism 的普通 REST
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
            c.setConnectTimeout(5000);
            c.setReadTimeout(30_000);
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

    // ============================================================
    // 回传结果
    // ============================================================
    private void report(String commandId, String sessionId, Object result, String error) {
        try {
            JSONObject body = new JSONObject();
            body.put("command_id", commandId);
            if (sessionId != null && !sessionId.isEmpty()) body.put("session_id", sessionId);
            body.put("events", new JSONArray());
            body.put("done", true);
            if (error != null) body.put("error", error);
            else body.put("result", result == null ? JSONObject.NULL : result);
            post("/api/v1/device/report", body);
            Log.i(TAG, (error == null ? "指令完成" : "指令失败：" + error));
        } catch (Throwable t) {
            Log.w(TAG, "回传失败：" + t.getMessage());
        }
    }

    // ============================================================
    // 网关 HTTP（带设备凭据头）
    // ============================================================
    private JSONObject post(String path, JSONObject body) throws Exception {
        String base = AgentPrefs.endpoint(appCtx);
        HttpURLConnection c = (HttpURLConnection) new URL(base + path).openConnection();
        try {
            c.setRequestMethod("POST");
            c.setRequestProperty("Content-Type", "application/json");
            // ★ 必须伪装浏览器 UA：Cloudflare 会拦 Java/urllib 的默认 UA（403）
            c.setRequestProperty("User-Agent",
                    "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 "
                            + "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36");
            c.setRequestProperty("X-Device-Id", AgentPrefs.deviceId(appCtx));
            c.setRequestProperty("X-Device-Token", AgentPrefs.token(appCtx));
            c.setConnectTimeout(10_000);
            c.setReadTimeout(40_000);
            c.setDoOutput(true);
            OutputStream os = c.getOutputStream();
            os.write(body.toString().getBytes(StandardCharsets.UTF_8));
            os.close();

            int code = c.getResponseCode();
            InputStream is = (code >= 400) ? c.getErrorStream() : c.getInputStream();
            String s = is == null ? "" : readAll(is);
            if (s.trim().isEmpty()) s = "{}";
            return new JSONObject(s);
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

    private static String enc(String s) {
        try {
            return java.net.URLEncoder.encode(s == null ? "" : s, "UTF-8");
        } catch (Exception e) {
            return "";
        }
    }
}

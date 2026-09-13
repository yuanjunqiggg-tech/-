#!/usr/bin/env python3
"""
============================================================
Prism 被控端 Agent  ·  跑在云手机上
============================================================

职责
----
1. 注册 / 绑定设备（拿到 device_id + token，持久化到本地）
2. 心跳保活：上报在线状态、电量、Prism 是否在跑、机器人是否连服
3. 长轮询领取云端下发的指令
4. 在本机执行指令（转发到本机 Prism 的 /api/ai/chat 或 REST 端点）
5. 把执行过程（流式文本、工具调用、数据包）实时上报云端

运行环境
--------
- 安卓云手机：由 APK 的 WebView/Service 容器调用本脚本（或等价逻辑）
- 也可直接在桌面 / Termux 里跑，用于联调

用法
----
  python prism_agent.py                       # 首次运行会注册并打印 device_id
  python prism_agent.py --name "云手机1号"     # 指定设备名
  python prism_agent.py --register-only       # 只注册不启动循环

环境变量
--------
  PRISM_GATEWAY   云端网关地址（默认 https://ai-api.youyuanqi.dpdns.org）
  PRISM_URL       本机 Prism 地址（默认 http://127.0.0.1:8080）
  AGENT_STATE     状态文件路径（默认 ./agent_state.json）
============================================================
"""
import argparse
import json
import os
import platform
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ------------------------------------------------------------
# 配置
# ------------------------------------------------------------
def _normalize_gateway(u: str) -> str:
    """把网关地址归一化到「域名根」，因为 cloud() 会自己拼 /api/v1/...

    用户经常会把控制台里看到的完整地址（含 /api/v1）直接粘进来，
    这里统一容错，避免出现 /api/v1/api/v1/device/register 这种双拼。
    """
    u = (u or "").strip().rstrip("/")
    # 去掉末尾的 /api/v1、/api、/v1 等常见后缀
    u = re.sub(r"/api/v1/?$", "", u)
    u = re.sub(r"/api/?$", "", u)
    return u.rstrip("/")


GATEWAY = _normalize_gateway(os.environ.get("PRISM_GATEWAY", "https://ai-api.youyuanqi.dpdns.org"))
PRISM_URL = os.environ.get("PRISM_URL", "http://127.0.0.1:8080").rstrip("/")
# Prism 地址也可能被误填带后缀，做同样处理
PRISM_URL = re.sub(r"/(api|api/v1)$", "", PRISM_URL)
STATE_PATH = os.environ.get("AGENT_STATE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent_state.json"))

# 本机 Prism 走直连；云端网关默认也直连（避免系统代理劫持 127.0.0.1 造成 502）
os.environ.setdefault("NO_PROXY", "localhost,127.0.0.1,::1")
os.environ.setdefault("no_proxy", "localhost,127.0.0.1,::1")

# ★ 关键：explicitly 绕过代理，不要依赖 NO_PROXY 环境变量。
#   实测在 Windows + 系统代理（如 7897 端口）环境下，urllib 默认 opener
#   仍会把 127.0.0.1 / 局域网请求丢给代理，导致 "Tunnel connection failed: 502"。
_local_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# ★ 云端 opener：默认完全绕过系统代理。
#
#   踩坑记录（Windows + 系统代理 127.0.0.1:61543）：
#     - 用 build_opener() 会读取系统代理，把 127.0.0.1 请求丢给代理，
#       报 "Tunnel connection failed: 502 Bad Gateway"；
#     - 子类化 ProxyHandler 覆写 proxy_open 返回 None 也不行，
#       返回 None 的语义是「本 handler 不处理」，urllib 仍会走代理；
#     - Windows 的 proxy_bypass 对 127.0.0.1 默认返回 False。
#
#   结论：直连最稳。若你的网络确实需要代理才能访问外网，
#   显式设置环境变量 PRISM_USE_SYSTEM_PROXY=1 即可恢复系统代理。
if os.environ.get("PRISM_USE_SYSTEM_PROXY") == "1":
    _cloud_opener = urllib.request.build_opener()
else:
    _cloud_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

HEARTBEAT_SEC = 20      # 心跳间隔
POLL_WAIT = 25          # 每次长轮询挂起秒数
PRISM_TIMEOUT = 180


# ------------------------------------------------------------
# 状态持久化
# ------------------------------------------------------------
def load_state() -> dict:
    if os.path.exists(STATE_PATH):
        try:
            with open(STATE_PATH, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_state(st: dict):
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    with open(STATE_PATH, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=2)


# ------------------------------------------------------------
# HTTP 工具
# ------------------------------------------------------------
# ★ 必须伪装成浏览器 UA。
#   urllib 默认发 "Python-urllib/3.x"，Cloudflare 的 WAF 会直接 403 拒绝
#   （有时表现为 error 1010）。这不是「以防万一」——实测不加就注册不上。
UA_BROWSER = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")


def http(url: str, method="GET", body=None, headers=None, opener=None, timeout=60):
    h = {"Content-Type": "application/json", "User-Agent": UA_BROWSER}
    if headers:
        h.update(headers)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    op = opener or _cloud_opener
    with op.open(req, timeout=timeout) as r:
        raw = r.read().decode("utf-8", "replace")
    try:
        return json.loads(raw)
    except Exception:
        return {"raw": raw}


def cloud(path: str, method="GET", body=None, headers=None, timeout=60):
    """调云端网关。path 需自带 /api/v1 前缀。"""
    return http(f"{GATEWAY}{path}", method, body, headers=headers,
                opener=_cloud_opener, timeout=timeout)


def prism(path: str, method="GET", body=None, timeout=PRISM_TIMEOUT):
    """调本机 Prism（强制绕过系统代理）"""
    return http(f"{PRISM_URL}{path}", method, body, opener=_local_opener, timeout=timeout)


def log(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


# ------------------------------------------------------------
# 设备注册
# ------------------------------------------------------------
def do_register(state: dict, name: str = None, register_only=False) -> dict:
    meta = collect_meta()
    if name:
        meta["name"] = name

    if state.get("device_id") and state.get("token"):
        body = {**meta, "device_id": state["device_id"], "token": state["token"]}
        r = cloud("/api/v1/device/register", "POST", body)
        if r.get("ok"):
            log(f"设备已重新绑定：{state['device_id']}")
            return state
        log(f"重新绑定失败（{r.get('error')}），尝试重新注册…")
        state = {}

    r = cloud("/api/v1/device/register", "POST", meta)
    if not r.get("ok"):
        raise RuntimeError(f"注册失败：{r.get('error')}")

    d = r.get("data") or {}
    state = {"device_id": d.get("device_id"), "token": d.get("token")}
    save_state(state)
    log("=" * 56)
    log(f"  注册成功！")
    log(f"  device_id : {state['device_id']}")
    log(f"  token     : {state['token'][:12]}…（已存到 {STATE_PATH}）")
    log("=" * 56)
    return state


def collect_meta() -> dict:
    """采集设备信息"""
    prism_port = 8080
    m = re.match(r"https?://[^:]+:(\d+)", PRISM_URL)
    if m:
        prism_port = int(m.group(1))

    return {
        "platform": "android" if "android" in platform.platform().lower() or os.path.exists("/system/build.prop") else platform.system().lower(),
        "model": platform.machine(),
        "android_ver": platform.release(),
        "app_ver": "1.0.0",
        "prism_port": prism_port,
        "hostname": socket.gethostname(),
    }


# ------------------------------------------------------------
# 心跳
# ------------------------------------------------------------
def probe_prism() -> dict:
    """探测本机 Prism 与机器人状态"""
    out = {"prism_online": False, "bot_connected": False, "bot_server": ""}
    try:
        cfg = prism("/api/config", timeout=8)
        out["prism_online"] = bool(cfg.get("ok") or cfg.get("config") is not None)
    except Exception:
        return out

    try:
        bot = prism("/api/bot/status", timeout=8)
        out["bot_connected"] = bool(bot.get("connected"))
        out["bot_server"] = bot.get("server", "") or ""
    except Exception:
        pass
    return out


def read_battery() -> int:
    """安卓上读电量（读不到返回 -1）"""
    for p in ("/sys/class/power_supply/battery/capacity",
              "/sys/class/power_supply/BAT0/capacity"):
        try:
            with open(p) as f:
                return int(f.read().strip())
        except Exception:
            continue
    return -1


def send_heartbeat(state: dict) -> int:
    """发心跳，返回待办指令数"""
    st = probe_prism()
    body = {
        "prism_online": st["prism_online"],
        "bot_connected": st["bot_connected"],
        "bot_server": st["bot_server"],
        "battery": read_battery(),
    }
    try:
        r = cloud("/api/v1/device/heartbeat", "POST", body,
                  headers=device_headers(state), timeout=20)
        if r.get("ok"):
            return (r.get("data") or {}).get("pending", 0)
        log(f"心跳被拒：{r.get('error')}")
    except Exception as e:
        log(f"心跳异常：{e}")
    return 0


def device_headers(state: dict) -> dict:
    return {
        "X-Device-Id": state.get("device_id", ""),
        "X-Device-Token": state.get("token", ""),
    }


# ------------------------------------------------------------
# 指令执行
# ------------------------------------------------------------
def report(state: dict, cmd_id: str, events: list, done=False, result=None, error=None, session_id=None):
    """上报事件（失败不中断主流程）"""
    body = {
        "command_id": cmd_id,
        "events": events,
        "session_id": session_id,
        "done": done,
    }
    if result is not None:
        body["result"] = result
    if error:
        body["error"] = str(error)[:2000]
    try:
        cloud("/api/v1/device/report", "POST", body,
              headers=device_headers(state), timeout=30)
    except Exception as e:
        log(f"上报失败：{e}")


def chat_stream(payload: dict, on_event, retry: int = 2):
    """
    调 Prism /api/ai/chat，逐块解析 SSE 并回调。
    这是流式反馈的关键——不能等整个响应读完再返回。

    ★ 重试：Prism 在并发新建会话时偶尔会返回空流（无任何事件）。
      这里对「空响应」自动重试，避免工具调用静默失败。
    """
    last = {"text": "", "tools": []}
    for attempt in range(retry + 1):
        r = _chat_stream_once(payload, on_event)
        last = r
        # 有工具结果或文本，视为成功
        if r["tools"] or r["text"].strip():
            return r
        if attempt < retry:
            log(f"  ⚠ Prism 返回空响应，重试 {attempt + 1}/{retry}")
            time.sleep(1.0 + attempt)
    return last


def _chat_stream_once(payload: dict, on_event):
    body = {
        "model_name": payload.get("model_name", "prism自动"),
        "plugin_id": payload.get("plugin_id", ""),
        "mode": payload.get("mode", ""),
        "session_name": payload.get("session_name") or f"dev-{int(time.time())}",
        "messages": payload.get("messages") or [],
    }
    req = urllib.request.Request(
        f"{PRISM_URL}/api/ai/chat",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    text_all, tools_done = [], []

    def handle_block(block: str):
        """解析一个 SSE 事件块并回调"""
        ev, data = None, None
        for line in block.split("\n"):
            line = line.rstrip("\r")
            if line.startswith("event:"):
                ev = line[6:].strip()
            elif line.startswith("data:"):
                payload_str = line[5:].strip()
                try:
                    data = json.loads(payload_str)
                except Exception:
                    data = {"raw": payload_str}
        if not ev:
            return

        # 映射成云端事件类型
        if ev == "ai_chunk" and (data or {}).get("text"):
            text_all.append(data["text"])
            on_event({"type": "chunk", "payload": {"text": data["text"]}})
        elif ev == "ai_thinking" and (data or {}).get("text"):
            on_event({"type": "thinking", "payload": {"text": data["text"]}})
        elif ev == "ai_tool_start":
            on_event({"type": "tool_start", "payload": data})
        elif ev == "ai_tool_done":
            tools_done.append(data)
            on_event({"type": "tool_done", "payload": data})
        elif ev == "ai_usage":
            on_event({"type": "usage", "payload": data})
        elif ev == "ai_error":
            on_event({"type": "error", "payload": data})
        elif ev == "ai_done":
            # ★ 注意：这是「AI 这一轮回复结束」，不是「整条指令执行完毕」。
            #   用 ai_round_done 与指令级的 done 区分开，避免 Worker 误收尾。
            on_event({"type": "ai_round_done", "payload": data})

    with _local_opener.open(req, timeout=PRISM_TIMEOUT) as resp:
        buf = ""
        # ★ 用较大分块读，减少切分次数；并且在流结束后处理残余 buf，
        #   避免最后一个事件（常见于 ai_tool_done / ai_done）因缺少结尾空行被丢弃
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            buf += chunk.decode("utf-8", "replace")
            while "\n\n" in buf:
                idx = buf.index("\n\n")
                block, buf = buf[:idx], buf[idx + 2:]
                handle_block(block)

        # 流结束：处理残留内容（可能是最后一个没带 \n\n 的事件）
        tail = buf.strip()
        if tail:
            handle_block(tail)

    return {"text": "".join(text_all), "tools": tools_done}


def exec_command(state: dict, cmd: dict):
    """执行一条云端指令"""
    cid = cmd.get("id")
    kind = cmd.get("kind")
    payload = cmd.get("payload") or {}
    sid = cmd.get("session_id")
    log(f"▶ 执行指令 {cid} [{kind}]")

    # 事件攒批，减少请求数
    batch = []
    last_flush = time.time()

    def flush(force=False):
        nonlocal batch, last_flush
        if batch and (force or len(batch) >= 20 or time.time() - last_flush > 2):
            report(state, cid, batch, session_id=sid)
            batch = []
            last_flush = time.time()

    def on_event(e):
        batch.append(e)
        flush()

    try:
        # ---------------- chat ----------------
        if kind == "chat":
            # ★ 兼容两种入参：
            #     a) messages: [{role, content}, ...]  —— 完整对话
            #     b) prompt: "一句话"                  —— 便捷简写（控制台默认用这个）
            if not payload.get("messages") and payload.get("prompt"):
                payload = dict(payload)
                payload["messages"] = [{"role": "user", "content": str(payload["prompt"])}]

            if not payload.get("messages"):
                flush(force=True)
                report(state, cid, [], done=True,
                       error="chat 指令缺少内容（需要 payload.prompt 或 payload.messages）",
                       session_id=sid)
                return

            # 每次对话用稳定的会话名，便于在 Prism 里连续追问
            if not payload.get("session_name"):
                payload = dict(payload)
                payload["session_name"] = f"remote-{state.get('device_id', 'dev')[-6:]}"

            r = chat_stream(payload, on_event)
            flush(force=True)
            report(state, cid, [], done=True,
                   result={"text": r["text"], "tools": r["tools"]}, session_id=sid)

        # ---------------- tool ----------------
        elif kind == "tool":
            # ★ 兼容两套字段名（控制台历史版本用 tool/input，MCP 侧用 tool_name/arguments）
            tn = payload.get("tool_name") or payload.get("tool") or payload.get("name")
            args = payload.get("arguments")
            if args is None:
                args = payload.get("input")
            if args is None:
                args = payload.get("args")
            args = args or {}

            if not tn or tn == "None":
                flush(force=True)
                report(state, cid, [], error="指令缺少工具名（应为 payload.tool_name）", session_id=sid)
                return

            sys_p = ("你是工具执行器。用户会指定一个工具名和参数，"
                     "你必须立即发起该工具的 tool_calls，不要解释、不要闲聊、不要修改参数。"
                     "只调用这一个工具，然后简短说明结果。")
            usr_p = (f"请立即调用工具 `{tn}`，参数如下（JSON）：\n"
                     f"{json.dumps(args, ensure_ascii=False, indent=2)}\n\n只调用这一个工具。")
            r = chat_stream({
                "model_name": payload.get("model_name", "prism自动"),
                "plugin_id": payload.get("plugin_id", ""),
                "session_name": payload.get("session_name"),
                "messages": [
                    {"role": "system", "content": sys_p},
                    {"role": "user", "content": usr_p},
                ],
            }, on_event)
            flush(force=True)
            tool_res = r["tools"][-1] if r["tools"] else None
            parsed = None
            if tool_res and isinstance(tool_res.get("result"), str):
                try:
                    parsed = json.loads(tool_res["result"])
                except Exception:
                    parsed = tool_res["result"]
            elif tool_res:
                parsed = tool_res.get("result")
            report(state, cid, [], done=True, result={
                "ok": bool(tool_res) and not tool_res.get("is_error"),
                "tool": (tool_res or {}).get("name"),
                "executed": (tool_res or {}).get("evidence") == "executed",
                "result": parsed,
                "ai_comment": r["text"][:800],
            }, session_id=sid)

        # ---------------- packet_sub ----------------
        elif kind == "packet_sub":
            duration = min(int(payload.get("duration", 10)), 60)
            ptype = payload.get("packet_type", "")
            deadline = time.time() + duration
            captured, rounds = [], 0
            while time.time() < deadline and rounds < 30:
                rounds += 1
                wargs = {"seconds": 3}
                if ptype:
                    wargs["packet_type"] = ptype
                sys_p = ("你是工具执行器。你必须立即调用 wait_packet 工具，"
                         "不要解释、不要闲聊。只调用这一个工具。")
                usr_p = (f"请立即调用工具 `wait_packet`，参数：\n"
                         f"{json.dumps(wargs, ensure_ascii=False)}\n\n只调用这一个工具。")
                r = chat_stream({
                    "model_name": "prism自动",
                    "session_name": f"sub-{int(time.time()*1000)}",
                    "messages": [
                        {"role": "system", "content": sys_p},
                        {"role": "user", "content": usr_p},
                    ],
                }, on_event)
                for t in r["tools"]:
                    if not t.get("is_error") and t.get("evidence") == "executed":
                        captured.append(t.get("result"))
                        on_event({"type": "packet", "payload": {
                            "raw": t.get("result"), "at": int(time.time() * 1000),
                        }})
                flush()
            flush(force=True)
            report(state, cid, [], done=True, result={
                "action": "subscribe", "duration": duration,
                "packet_type": ptype or "(全部)", "rounds": rounds,
                "captured": len(captured), "packets": captured[:100],
            }, session_id=sid)

        # ---------------- packet_send ----------------
        elif kind == "packet_send":
            tn = payload.get("packet_type")
            sys_p = "你是工具执行器。你必须立即调用 send_packet 工具。只调用这一个工具。"
            usr_p = (f"请立即调用工具 `send_packet`，参数：\n"
                     f"{json.dumps({'type': tn, 'data': payload.get('data') or {}}, ensure_ascii=False)}\n\n"
                     f"只调用这一个工具。")
            r = chat_stream({
                "model_name": "prism自动",
                "session_name": f"send-{int(time.time()*1000)}",
                "messages": [
                    {"role": "system", "content": sys_p},
                    {"role": "user", "content": usr_p},
                ],
            }, on_event)
            flush(force=True)
            report(state, cid, [], done=True,
                   result={"sent": bool(r["tools"]), "packets": r["tools"]}, session_id=sid)

        # ---------------- prism_rest ----------------
        elif kind == "prism_rest":
            r = prism(payload.get("path", "/api/bot/status"),
                      payload.get("method", "GET"), payload.get("body"))
            report(state, cid, [], done=True, result=r, session_id=sid)

        else:
            report(state, cid, [], done=True, error=f"未知指令类型 {kind}")

    except urllib.error.URLError as e:
        flush(force=True)
        report(state, cid, [], done=True, error=f"连接 Prism 失败：{e}")
    except Exception as e:
        flush(force=True)
        report(state, cid, [], done=True, error=f"{type(e).__name__}: {e}")


# ------------------------------------------------------------
# 主循环
# ------------------------------------------------------------
def main_loop(state: dict):
    log(f"进入主循环 | 网关={GATEWAY} | 本机 Prism={PRISM_URL}")
    last_hb = 0.0

    while True:
        try:
            # 心跳
            if time.time() - last_hb > HEARTBEAT_SEC:
                pending = send_heartbeat(state)
                st = probe_prism()
                log(f"♥ 心跳 | Prism={'✓' if st['prism_online'] else '✗'} "
                    f"机器人={'✓' if st['bot_connected'] else '✗'} "
                    f"待办={pending} 电量={read_battery()}%")
                last_hb = time.time()

            # 长轮询领指令
            r = cloud("/api/v1/device/poll", "POST", {"wait": POLL_WAIT},
                      headers=device_headers(state), timeout=POLL_WAIT + 15)

            if not r.get("ok"):
                log(f"轮询失败：{r.get('error')}（10 秒后重试）")
                time.sleep(10)
                continue

            cmd = (r.get("data") or {}).get("command")
            if cmd:
                exec_command(state, cmd)
            else:
                last_hb = min(last_hb, time.time() - HEARTBEAT_SEC + 5)

        except KeyboardInterrupt:
            log("收到中断，退出")
            break
        except Exception as e:
            log(f"主循环异常：{type(e).__name__}: {e}（5 秒后重试）")
            time.sleep(5)


# ------------------------------------------------------------
# 入口
# ------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Prism 被控端 Agent")
    ap.add_argument("--name", help="设备名称")
    ap.add_argument("--gateway", help="覆盖网关地址")
    ap.add_argument("--prism", help="覆盖本机 Prism 地址")
    ap.add_argument("--register-only", action="store_true", help="只注册，不启动循环")
    ap.add_argument("--reset", action="store_true", help="清除本地状态重新注册")
    args = ap.parse_args()

    global GATEWAY, PRISM_URL
    if args.gateway:
        GATEWAY = _normalize_gateway(args.gateway)
    if args.prism:
        PRISM_URL = args.prism.rstrip("/")
        PRISM_URL = re.sub(r"/(api|api/v1)$", "", PRISM_URL)

    log(f"网关地址 = {GATEWAY}")

    state = {} if args.reset else load_state()
    state = do_register(state, args.name)

    if args.register_only:
        log("仅注册模式，退出")
        return

    # 连通性自检
    st = probe_prism()
    if st["prism_online"]:
        log("✓ 本机 Prism 可达")
    else:
        log("✗ 本机 Prism 不可达 —— 请确认 Prism 已启动，端口正确")
        log(f"  提示：本机代理可能拦截 127.0.0.1，本脚本已强制绕过")

    main_loop(state)


if __name__ == "__main__":
    main()

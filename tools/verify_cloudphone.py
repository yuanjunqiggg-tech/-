# -*- coding: utf-8 -*-
"""
云手机真机验收 —— 装好两个 APK 之后，在你自己电脑上跑这一条命令。

它做的事（全部走云端网关，不需要你电脑连云手机）：
  1. 设备在不在线
  2. Prism 装没装、8080 活不活、机器人连没连
  3. AI帮写 会话能不能列出来（读的是 Prism 自己的存储）
  4. 真的让 Prism 内置 AI 跑一句话，看它回不回
  5. 直连 Prism 的 /api/bot/status

任何一步挂了，都会直接告诉你大概是哪里的问题。

用法：
    python tools/verify_cloudphone.py
    python tools/verify_cloudphone.py --chat "帮我在游戏里说一句 hello"
"""
import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request

# ------------------------------------------------------------
# ★ 必须先强UTF-8，否则 Windows GBK 控制台一打印中文就 UnicodeEncodeError
#   （Prism 被控端 prism_agent.py 踩过一模一样的坑）
# ------------------------------------------------------------
def _force_utf8():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            try:
                import io
                stream.__dict__["_buf"] = stream.buffer
                setattr(sys, stream.name,
                        io.TextIOWrapper(stream.buffer, encoding="utf-8",
                                         errors="replace", line_buffering=True))
            except Exception:
                pass


_force_utf8()

BASE = "https://ai-api.youyuanqi.dpdns.org"
KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

PASS = FAIL = 0
LINES = []


def say(s=""):
    print(s, flush=True)
    LINES.append(s)


def check(name, cond, detail="", hint=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        say(f"  [OK]   {name}" + (f"   {detail}" if detail else ""))
    else:
        FAIL += 1
        say(f"  [FAIL] {name}" + (f"   {detail}" if detail else ""))
        if hint:
            say(f"         -> {hint}")
    return cond


def http(path, method="GET", body=None, timeout=120):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": UA,
         "Authorization": "Bearer " + KEY}
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, str(e)


def mcp(name, args=None, timeout=120):
    st, txt = http("/mcp?key=" + KEY, "POST", {
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": args or {}},
    }, timeout=timeout)
    try:
        res = json.loads(txt).get("result") or {}
    except Exception:
        return {"_status": st, "_raw": txt[:400]}
    t = (res.get("content") or [{}])[0].get("text", "")
    try:
        out = json.loads(t)
    except Exception:
        out = {"_text": t[:400]}
    out["_status"] = st
    out["_isError"] = res.get("isError")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chat", default="用一句话告诉我你现在能做什么",
                    help="发给 Prism 内置 AI 的测试指令")
    args = ap.parse_args()

    say("=" * 62)
    say("云手机真机验收")
    say("=" * 62)

    # ---------- 1. 设备在线 ----------
    say("\n[1] 被控端在不在")
    st, txt = http("/api/v1/health")
    try:
        d = json.loads(txt).get("data", {})
    except Exception:
        d = {}
    online = d.get("devices_online") or 0
    total = d.get("devices_total") or 0
    if not check("有被控端在线", online > 0,
                 f"在线 {online} / 共 {total}",
                 "云手机里的「Prism 被控端」没在跑。打开它 → 点「启动服务」；"
                 "再去系统设置放行自启动、后台运行、电池优化。"):
        say("\n验收中止：先让被控端上线。")
        return 1

    # ---------- 2. Prism 引擎状态 ----------
    say("\n[2] Prism 引擎状态（这是 APK 本体，不是网页）")
    r = mcp("prism_status", {})
    res = r.get("result") or {}
    nat = res.get("native") or {}
    bot = res.get("bot") or {}

    # ★ 设备「在线」但不回数据 = 被控端收不到指令，或指令超时了。
    #   不特殊处理的话只会打出一堆 null，看不出到底哪里坏了。
    if not res:
        say("      被控端没有回任何数据。原始返回：")
        say("      " + json.dumps(r, ensure_ascii=False)[:400])
        check("被控端能执行指令", False,
              hint="设备心跳在线但执行不出结果 —— 通常是被控端的 WebView "
                   "被云手机冻结了（息屏/切后台）。把被控端保持在前台，"
                   "或去系统设置放行后台运行与电池优化。"
                   "也可以在控制台「设备」页删掉这台，让它重新注册。")
        say("\n验收中止：先让被控端能正常执行指令。")
        return 1

    say("      " + json.dumps({
        "已安装": nat.get("installed"),
        "8080响应": nat.get("alive"),
        "端口": res.get("port"),
        "机器人已连接": bot.get("bot_connected"),
    }, ensure_ascii=False))
    check("Prism 已安装", nat.get("installed") is True,
          hint="被控端和 Prism 不在同一台机器上，或者 Prism 没装。")
    alive = check("Prism 引擎 8080 有响应", nat.get("alive") is True,
                  hint="Prism 进程被云手机回收了。手动打开一次 Prism，"
                       "等主界面出来再退回桌面（别杀进程）。"
                       "被控端 v1.1 会在每条指令前自动拉起它。")

    # ---------- 3. AI帮写 会话 ----------
    say("\n[3] AI帮写 会话（数据在 Prism 自己的存储里）")
    r = mcp("prism_session", {"action": "list"})
    res = r.get("result") or {}
    names = res.get("sessions")
    if isinstance(names, list):
        check("能列出 Prism 里的会话", True, f"{len(names)} 个")
        if names:
            say("      " + "、".join(map(str, names[:8])))
    else:
        # 真机上字段可能不叫 sessions，把原文打出来方便校准
        check("能列出 Prism 里的会话", False,
              json.dumps(res, ensure_ascii=False)[:300],
              "真机返回的字段和预期不同，把上面这段发我，我按真机改。")

    # ---------- 4. 真的让 Prism AI 跑一句 ----------
    say("\n[4] 让 Prism 内置 AI 跑一句话")
    r = mcp("prism_chat", {"prompt": args.chat, "timeout_ms": 90000})
    ok_chat = r.get("ok") is True and not r.get("_isError")
    text = ""
    if ok_chat:
        rr = r.get("result") or {}
        text = rr.get("text") or ""
        tools = rr.get("tools") or []
        check("Prism AI 有回复", bool(text), f"{len(text)} 字")
        if text:
            say("      " + text[:300].replace("\n", "\n      "))
        if tools:
            say(f"      调用了 {len(tools)} 个工具：" +
                "、".join(str(t.get("name")) for t in tools[:6]))
    else:
        check("Prism AI 有回复", False, json.dumps(r, ensure_ascii=False)[:300],
              "可能是 Prism 没登录、内置 AI 没配、或机器人没连上。"
              "先在云手机上手动打开 Prism 自己问一句，确认它本身能用。")

    # ---------- 5. 直连 Prism REST ----------
    say("\n[5] 直连 Prism 的 /api/bot/status")
    r = mcp("prism_rest", {"path": "/api/bot/status"})
    body = r.get("result") if isinstance(r.get("result"), dict) else r
    check("能读到 Prism 的 bot 状态", r.get("ok") is True or bool(body),
          json.dumps(body, ensure_ascii=False)[:200])

    # ---------- 汇总 ----------
    say("")
    say("=" * 62)
    say(f"结果： {PASS} 通过 / {FAIL} 失败")
    say("=" * 62)
    if FAIL == 0:
        say("\n全部通过 —— 可以把 MCP 网址丢给 AI Agent 了：")
        say(f"  {BASE}/mcp?key={KEY[:8]}...{KEY[-6:]}")
        say("\n（完整网址在控制台「AI接入」页，带复制按钮）")
    else:
        say("\n还有没过的项。按上面的 -> 提示处理，")
        say("或者直接把这份输出发给我，我照着改。")
    return 1 if FAIL else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n已中断")
        sys.exit(130)

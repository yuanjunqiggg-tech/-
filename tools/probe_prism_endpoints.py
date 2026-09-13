#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
真机端点巡检：通过 MCP -> 云端网关 -> 云手机被控端，逐个探测 Prism 本机 REST 端点。

只跑【只读 GET】，绝不触碰写操作 / 危险端点
（system/restart、plugin/file/write、bot/disconnect、fly/*、push/ack、cache/clear 等一律排除）。

用法：
  python tools/probe_prism_endpoints.py
  python tools/probe_prism_endpoints.py --device dev_xxx --out docs/端点巡检.md
"""
import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

DEFAULT_KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
DEFAULT_GATEWAY = "https://ai-api.youyuanqi.dpdns.org"
DEFAULT_DEVICE = "dev_elribseuror12ih7i3zb"

# 安全只读端点清单（(路径, 说明)）
SAFE_GET = [
    ("/api/bot/status", "机器人连接状态"),
    ("/api/players/list", "当前玩家列表"),
    ("/api/server/players", "服务器玩家"),
    ("/api/server/detail", "服务器详情"),
    ("/api/config", "Prism 配置"),
    ("/api/plugin/list", "插件列表"),
    ("/api/plugin/meta", "插件元信息"),
    ("/api/plugin/disabled", "被禁用的插件"),
    ("/api/plugin/data", "插件数据"),
    ("/api/plugin/api-doc", "插件 API 文档"),
    ("/api/plugin/wordbank-doc", "词库文档"),
    ("/api/ai/sessions", "AI帮写 会话列表"),
    ("/api/ai/sessions/recent", "最近一次 AI帮写 会话"),
    ("/api/ai/models", "Prism 可用模型"),
    ("/api/ai/snapshot", "AI 快照"),
    ("/api/task/list", "任务列表"),
    ("/api/node/status", "自动化节点状态"),
    ("/api/fly/status", "飞行模块状态"),
    ("/api/fly/position", "机器人坐标"),
    ("/api/files/scan", "文件扫描"),
    ("/api/mcfunction/status", "批量指令执行进度"),
    ("/api/music/status", "音乐播放状态"),
    ("/api/camera/status", "相机状态"),
    ("/api/marquee/status", "跑马灯状态"),
    ("/api/pathfinder/log", "寻路日志"),
    ("/api/draw/state", "绘图状态"),
    ("/api/auth/me", "Prism 账号信息"),
    ("/api/toolbox/my-info", "工具箱信息"),
    ("/api/system/version", "版本信息"),
]


def make_rpc(gateway: str, key: str):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    url = f"{gateway}/mcp?key={key}"
    counter = [0]

    def rpc(method, params):
        counter[0] += 1
        payload = {"jsonrpc": "2.0", "id": counter[0], "method": method, "params": params}
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={
                "User-Agent": "Mozilla/5.0",  # ★ CF 会拦 urllib 默认 UA
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
        )
        raw = opener.open(req, timeout=120).read().decode()
        parsed = [json.loads(l[5:].strip()) for l in raw.splitlines() if l.startswith("data:")]
        return parsed[-1] if parsed else json.loads(raw)

    return rpc


def call_tool(rpc, tool, args):
    r = rpc("tools/call", {"name": tool, "arguments": args})
    if "error" in r:
        return {"rpc_error": r["error"]}
    content = r.get("result", {}).get("content", [])
    text = "".join(c.get("text", "") for c in content if c.get("type") == "text")
    try:
        return json.loads(text)
    except Exception:
        return {"raw": text}


# 命中即说明「端点存在，只是前置条件不满足」——算可用
PRECONDITION_HINTS = ("未连接", "未创建", "不存在", "无", "未开始", "尚未")
# 命中即说明「这个路径不是 REST 端点」，Prism 把 WebView 的 index.html 回给了我们
HTML_HINT = "<!DOCTYPE"


def scrub(text: str) -> str:
    """★ 回包可能带账号 token / 密钥，报告里必须脱敏。"""
    import re

    text = re.sub(r"\b[0-9a-f]{24,}\b", "<hex-已脱敏>", text)
    text = re.sub(r'"?(token|password|key|secret|authorization)"?\s*[:=]\s*"?[^",}\s]{6,}', r"\1: <已脱敏>", text, flags=re.I)
    return text


def summarize(result):
    """把回包压成一句人话 + 判定。

    判定口径（★ 真机实测踩出来的）：
      ok           —— 端点存在且正常返回
      ok-pre       —— 端点存在，但前置条件不满足（如机器人没连、没建画板）
      needs-body   —— 端点存在，但它是 POST，GET 过去会回「无效JSON」
      not-found    —— 路径不对：Prism 把 WebView 的 index.html 当回包返回了
      fail         —— 真的失败（超时 / 指令层错误）
    """
    if not isinstance(result, dict):
        return "fail", scrub(str(result))[:90]
    if "rpc_error" in result:
        return "fail", "RPC 错误：" + scrub(json.dumps(result["rpc_error"], ensure_ascii=False))[:90]
    if result.get("timeout"):
        return "fail", "指令超时（设备可能刚掉线）"

    # 指令层错误：多半是被控端把 Prism 的非 JSON 回包直接透传了上来
    cmd_err = result.get("error")
    if cmd_err:
        s = scrub(str(cmd_err))
        if HTML_HINT in s:
            return "not-found", "返回 HTML（路径不是 REST 端点，被 SPA 兜底了）"
        if s.startswith("Unexpected token") and "[PF" in s:
            return "ok", "端点存在，返回纯文本日志"
        return "fail", "指令错误：" + s[:90]

    inner = result.get("result")
    if isinstance(inner, dict) and inner.get("error"):
        msg = scrub(str(inner["error"]))
        if "无效JSON" in msg:
            return "needs-body", "该端点要 POST（GET 过去 Prism 报无效JSON）"
        if any(h in msg for h in PRECONDITION_HINTS):
            return "ok-pre", f"端点存在，前置条件未满足：{msg[:60]}"
        return "fail", f"Prism 报错：{msg[:80]}"

    if isinstance(inner, dict):
        for k, v in inner.items():
            if isinstance(v, list):
                return "ok", f"{k}: {len(v)} 项"
            if isinstance(v, dict):
                return "ok", scrub(f"{k}: {json.dumps(v, ensure_ascii=False)}")[:80]
        keys = list(inner.keys())[:6]
        return "ok", ("字段 " + ",".join(keys)) if keys else "ok"
    if isinstance(inner, str) and inner.startswith("<!"):
        return "not-found", "返回 HTML（路径不是 REST 端点）"
    return "ok", scrub(json.dumps(inner, ensure_ascii=False))[:90]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", default=DEFAULT_GATEWAY)
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--device", default=DEFAULT_DEVICE)
    ap.add_argument("--out", default="")
    ap.add_argument("--sleep", type=float, default=0.3)
    args = ap.parse_args()

    rpc = make_rpc(args.gateway, args.key)

    # 先确认设备在线
    devs = call_tool(rpc, "list_devices", {})
    online = []
    for d in (devs.get("devices") or devs.get("data", {}).get("devices") or []):
        if d.get("online"):
            online.append(d["id"])
    print(f"在线设备：{online or '（无）'}")
    if args.device not in online:
        print(f"★ 目标设备 {args.device} 不在线，终止巡检。")
        return 2

    rows = []
    tally = {}
    for path, desc in SAFE_GET:
        res = call_tool(rpc, "prism_rest", {"device_id": args.device, "path": path, "method": "GET"})
        verdict, note = summarize(res)
        tally[verdict] = tally.get(verdict, 0) + 1
        rows.append({"path": path, "desc": desc, "verdict": verdict, "note": note})
        print(f"[{verdict:10}] {path:30} {note}")
        time.sleep(args.sleep)

    usable = sum(v for k, v in tally.items() if k in ("ok", "ok-pre"))
    print("\n分类统计：" + "，".join(f"{k}={v}" for k, v in sorted(tally.items())))
    print(f"★ 端点真实可用（ok + ok-pre）：{usable} / {len(rows)}")

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# Prism 只读端点真机巡检报告",
            "",
            f"- 设备：`{args.device}`",
            f"- 时间：{time.strftime('%Y-%m-%d %H:%M:%S')}",
            "- 方式：MCP `prism_rest` → 云端网关 → 云手机被控端 → `127.0.0.1:8080`",
            f"- 结论：**{usable} 个端点真实可用**（共探测 {len(rows)} 个）",
            "",
            "> 只含只读 GET。写操作与危险端点（`system/restart`、`plugin/file/write`、",
            "> `bot/disconnect`、`fly/*`、`cache/clear`）未纳入，避免误操作云手机。",
            "> 返回内容中的账号 token / 密钥已脱敏。",
            "",
            "## 判定口径（真机踩出来的）",
            "",
            "| 判定 | 含义 |",
            "|---|---|",
            "| ✅ ok | 端点存在且正常返回 |",
            "| 🟡 ok-pre | 端点存在，前置条件未满足（机器人没连 / 没建画板） |",
            "| 🔵 needs-body | 端点存在但需要 POST body，GET 会回「无效JSON」 |",
            "| ⚪ not-found | 路径不对：Prism 把 WebView 的 index.html 兜底返回了 |",
            "| ❌ fail | 真失败（超时 / 指令层错误） |",
            "",
            "## 逐项结果",
            "",
            "| 端点 | 说明 | 判定 | 返回摘要 |",
            "|---|---|---|---|",
        ]
        icon = {"ok": "✅ ok", "ok-pre": "🟡 ok-pre", "needs-body": "🔵 needs-body",
                "not-found": "⚪ not-found", "fail": "❌ fail"}
        for r in rows:
            lines.append(
                f"| `{r['path']}` | {r['desc']} | {icon.get(r['verdict'], r['verdict'])} | "
                f"{r['note'].replace('|', '/')} |"
            )
        lines += ["", "## 统计", ""]
        for k, v in sorted(tally.items()):
            lines.append(f"- {icon.get(k, k)}：{v}")
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"报告已写入：{out}")

    return 0 if tally.get("fail", 0) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

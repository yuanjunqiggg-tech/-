#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wait_online.py —— 等设备上线，然后连着查机器人守护状态。

为什么需要这个：被控端是**断续上线**的（云手机锁屏 / 杀后台就会掉），
手敲一次 curl 经常正好赶上它离线，什么都问不到。
这个脚本会先轮询 /health 等它上线，一上线就立刻发 bot_keeper status，
并连续观察若干轮，直到抓到 connected=true。

用法：
    # 默认盯 本机一号，最多查 6 轮
    python tools/wait_online.py

    # 指定设备和轮数
    python tools/wait_online.py dev_vdk68bmm1swi5hsxaarn 10

看什么：
    connected=true   机器人已在服务器里（守护的最终目标）
    handshaking=true 刚发起连接、正在等服务器授权（这段时间不会重发，别慌）
    attempts         累计发起连接的次数；只涨而 fail_streak 不涨 = 正常在重连
"""
import json
import sys
import time
import urllib.request

K = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
G = "https://ai-api.youyuanqi.dpdns.org"
DEV = sys.argv[1] if len(sys.argv) > 1 else "dev_elribseuror12ih7i3zb"
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 6

OP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
HDR = {"User-Agent": "Mozilla/5.0", "Content-Type": "application/json"}


def get(path):
    r = OP.open(urllib.request.Request(G + path, headers=HDR), timeout=20)
    return json.loads(r.read().decode("utf-8", "replace"))


def mcp(tool, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": tool, "arguments": args}}).encode()
    r = OP.open(urllib.request.Request(f"{G}/mcp?key={K}", data=body, headers=HDR),
                timeout=90)
    d = json.loads(r.read().decode("utf-8", "replace"))
    return d.get("result", {}).get("content", [{}])[0].get("text", "(空)")


def stamp():
    return time.strftime("%H:%M:%S")


for rnd in range(ROUNDS):
    try:
        devs = get("/api/v1/health")["data"]["devices"]
        me = [x for x in devs if x["id"] == DEV]
        if not (me and me[0]["online"]):
            idle = me[0]["last_seen_ago_sec"] if me else -1
            print(f"[{stamp()}] 第{rnd+1}轮: 设备离线（心跳 {idle}s 前），等下一轮",
                  flush=True)
            time.sleep(10)
            continue

        txt = mcp("bot_keeper", {"action": "status", "device_id": DEV})
        try:
            d = json.loads(txt)
        except Exception:
            print(f"[{stamp()}] 第{rnd+1}轮: 返回无法解析: {txt[:200]}", flush=True)
            time.sleep(10)
            continue

        r = d.get("result") or {}
        if not r:
            # 设备在「在线」窗口内（90 秒）但还没开始下一轮长轮询，
            # 指令就超时了。不是故障，再等一轮通常就好。
            print(f"[{stamp()}] 第{rnd+1}轮: 指令未执行完"
                  f"（timeout={d.get('timeout')}），设备可能刚上线，再等一轮",
                  flush=True)
            time.sleep(10)
            continue

        print(f"[{stamp()}] 第{rnd+1}轮: connected={r.get('connected')} "
              f"handshaking={r.get('handshaking')} attempts={r.get('attempts')} "
              f"fail={r.get('fail_streak')} 消息={r.get('message')}", flush=True)

        if r.get("connected"):
            print(f"[{stamp()}] ★ 机器人已连上服务器 {r.get('server')}"
                  f"（维度 {r.get('dimension')}，OP={r.get('is_op')}）", flush=True)
            sys.exit(0)
    except Exception as e:
        print(f"[{stamp()}] 第{rnd+1}轮: 异常 {e}", flush=True)
    time.sleep(10)

print(f"[{stamp()}] {ROUNDS} 轮内没抓到 connected=true（设备断续上线所致）")

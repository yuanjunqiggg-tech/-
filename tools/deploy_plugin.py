#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本地 ds_ai_agent.lua 部署到真机：写文件 -> stop -> run -> 校验。

用法：
  python tools/deploy_plugin.py                       # 默认设备 dev_rbiiwxi7hcek6zzgeya3
  python tools/deploy_plugin.py --device dev_xxx
  python tools/deploy_plugin.py --dry                 # 只做语法检查，不上传
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")

KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
GW = "https://ai-api.youyuanqi.dpdns.org"
DEFAULT_DEVICE = "dev_rbiiwxi7hcek6zzgeya3"
PLUGIN_ID = "ds_ai_agent"


def make_rpc():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    url = f"{GW}/mcp?key={KEY}"
    counter = [0]

    def rpc(method, params):
        counter[0] += 1
        payload = {"jsonrpc": "2.0", "id": counter[0], "method": method, "params": params}
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"User-Agent": "Mozilla/5.0", "Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream"},
        )
        raw = opener.open(req, timeout=180).read().decode()
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


def rest(rpc, device, method, path, body=None):
    """prism_rest：把请求转发到设备本机 127.0.0.1:8080"""
    return call_tool(rpc, "prism_rest", {
        "device_id": device,
        "method": method,
        "path": path,
        "body": body if body is not None else {},
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default=DEFAULT_DEVICE)
    ap.add_argument("--file", default="prism_dump/plugin/ds_ai_agent.lua")
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()

    src = open(args.file, encoding="utf-8").read()
    md5 = hashlib.md5(src.encode("utf-8")).hexdigest()
    print(f"本地文件 {args.file}")
    print(f"  大小 {len(src):,} 字符 / {len(src.encode('utf-8')):,} 字节")
    print(f"  md5 {md5}")

    if args.dry:
        print("--dry 模式，不上传")
        return

    rpc = make_rpc()

    print("\n[1/5] 写插件源码 ...")
    r = rest(rpc, args.device, "POST", "/api/plugin/file/write",
             {"id": PLUGIN_ID, "scope": "code", "file": "", "content": src})
    print("  ->", json.dumps(r, ensure_ascii=False)[:400])
    if isinstance(r, dict) and r.get("rpc_error"):
        print("上传失败，中止")
        return

    time.sleep(1)
    print("\n[2/5] stop ...")
    print("  ->", json.dumps(rest(rpc, args.device, "POST", "/api/plugin/stop", {"id": PLUGIN_ID}), ensure_ascii=False)[:300])

    time.sleep(1)
    print("\n[3/5] run ...")
    print("  ->", json.dumps(rest(rpc, args.device, "POST", "/api/plugin/run", {"id": PLUGIN_ID}), ensure_ascii=False)[:300])

    time.sleep(3)
    print("\n[4/5] 读回校验（设备端 md5）...")
    back = rest(rpc, args.device, "GET", "/api/plugin/file/read?id=" + PLUGIN_ID + "&scope=code", None)
    s = json.dumps(back, ensure_ascii=False)
    print("  返回长度", len(s))
    if '"content"' in s:
        # 回包里 content 可能有转义，做个粗校验
        try:
            body = back.get("data") or back
            content = None
            if isinstance(body, dict):
                content = body.get("content") or (body.get("data") or {}).get("content")
            if content:
                print("  设备端 md5", hashlib.md5(content.encode("utf-8")).hexdigest())
                print("  一致" if hashlib.md5(content.encode("utf-8")).hexdigest() == md5 else "  ★ 不一致！")
            else:
                print("  未取到 content，原文前 300：", s[:300])
        except Exception as e:
            print("  解析异常", e, s[:300])
    else:
        print("  ", s[:300])

    print("\n[5/5] 运行状态 ...")
    print("  ->", json.dumps(rest(rpc, args.device, "GET", "/api/plugin/list", None), ensure_ascii=False)[:800])


if __name__ == "__main__":
    main()

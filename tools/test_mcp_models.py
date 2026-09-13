# -*- coding: utf-8 -*-
"""
验证三件新东西：
  1. 架构改造后 /health 不再依赖用户电脑隧道
  2. /mcp  MCP over HTTP（外部 AI Agent 接入）
  3. /api/v1/models  AI 模型管理（自己选、自己添加）

用法：python tools/test_mcp_models.py
"""
import json
import ssl
import sys
import urllib.request
import urllib.error

BASE = "https://ai-api.youyuanqi.dpdns.org"
KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

PASS = FAIL = 0


def http(path, method="GET", body=None, auth=True, timeout=60):
    url = BASE + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": UA}
    if auth:
        h["Authorization"] = "Bearer " + KEY
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")


def main():
    print("=" * 60)
    print("1. 健康检查（架构改造后）")
    print("=" * 60)
    st, txt = http("/api/v1/health", auth=False)
    check("health 返回 200", st == 200, f"status={st}")
    j = json.loads(txt)
    check("gateway online", j.get("data", {}).get("gateway") == "online", txt[:200])
    check("模式是 cloud-relay", j.get("data", {}).get("mode") == "cloud-relay", txt[:200])
    check("不再暴露 prism_tunnel_url",
          "prism_tunnel_url" not in txt, "仍然带着旧隧道字段")
    d = j.get("data", {})
    print(f"        在线设备 {d.get('devices_online')}/{d.get('devices_total')}")

    print()
    print("=" * 60)
    print("2. MCP over HTTP  /mcp?key=...")
    print("=" * 60)
    st, txt = http("/mcp", method="POST", auth=False,
                   body={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    check("无 key 时 401", st == 401, f"status={st} {txt[:150]}")

    st, txt = http("/mcp?key=" + KEY, method="POST", auth=False,
                   body={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    check("带 key 的 initialize 返回 200", st == 200, f"status={st} {txt[:200]}")
    j = json.loads(txt)
    check("协议版本正确", j.get("result", {}).get("protocolVersion") == "2024-11-05", txt[:200])
    check("serverInfo 存在", j.get("result", {}).get("serverInfo", {}).get("name") == "prism-remote", txt[:200])

    st, txt = http("/mcp?key=" + KEY, method="POST", auth=False,
                   body={"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    j = json.loads(txt)
    tools = [t["name"] for t in j.get("result", {}).get("tools", [])]
    check("tools/list 有工具", len(tools) >= 8, f"tools={tools}")
    print(f"        工具：{', '.join(tools)}")

    # 调一个不需要设备在线的工具
    st, txt = http("/mcp?key=" + KEY, method="POST", auth=False, body={
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "list_devices", "arguments": {}},
    })
    j = json.loads(txt)
    check("tools/call list_devices 成功",
          st == 200 and "devices" in j.get("result", {}).get("content", [{}])[0].get("text", ""),
          txt[:250])

    st, txt = http("/mcp?key=" + KEY, method="POST", auth=False, body={
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": {"name": "list_ai_models", "arguments": {}},
    })
    try:
        _ok = json.loads(txt)["result"]["content"][0]["text"]
        _ok = json.loads(_ok).get("ok") is True
    except Exception:
        _ok = False
    check("tools/call list_ai_models 成功", st == 200 and _ok, txt[:250])

    # 未知方法要报 -32601
    st, txt = http("/mcp?key=" + KEY, method="POST", auth=False,
                   body={"jsonrpc": "2.0", "id": 5, "method": "nope/nope", "params": {}})
    check("未知方法返回 -32601", json.loads(txt)["error"]["code"] == -32601, txt[:150])

    print()
    print("=" * 60)
    print("3. AI 模型管理  /api/v1/models")
    print("=" * 60)
    st, txt = http("/api/v1/models")
    check("列表返回 200", st == 200, f"status={st} {txt[:150]}")
    j = json.loads(txt)
    before = len(j.get("data", {}).get("models", []))
    print(f"        现有模型 {before} 个")

    st, txt = http("/api/v1/models", method="POST", body={})
    check("缺参数被拒 400", st == 400, f"status={st}")

    st, txt = http("/api/v1/models", method="POST", body={
        "name": "测试模型-勿用",
        "base_url": "https://api.deepseek.com/v1",
        "api_key": "sk-test1234567890abcdef",
        "model": "deepseek-chat",
    })
    check("新增模型成功", st == 200 and json.loads(txt).get("ok"), txt[:200])
    mid = json.loads(txt).get("data", {}).get("id")
    print(f"        新建模型 id = {mid}")

    st, txt = http("/api/v1/models")
    models = json.loads(txt)["data"]["models"]
    check("列表里能看到新模型", any(m["id"] == mid for m in models), txt[:200])
    m = [x for x in models if x["id"] == mid][0]
    check("★ 密钥已脱敏（不返回完整 key）",
          "sk-test1234567890abcdef" not in txt, "完整密钥泄漏了！")
    print(f"        key hint = {m.get('api_key_hint')}")

    st, txt = http("/api/v1/models/" + mid, method="PUT", body={"name": "测试模型-改名"})
    check("改名成功", st == 200 and json.loads(txt).get("ok"), txt[:150])

    st, txt = http("/api/v1/models/" + mid, method="DELETE")
    check("删除成功", st == 200 and json.loads(txt).get("ok"), txt[:150])

    st, txt = http("/api/v1/models/" + mid, method="DELETE")
    check("重复删除返回 404", st == 404, f"status={st}")

    print()
    print("=" * 60)
    print(f"结果： {PASS} 通过 / {FAIL} 失败")
    print("=" * 60)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

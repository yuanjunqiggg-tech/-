# -*- coding: utf-8 -*-
"""
假 Prism —— 只在 127.0.0.1:8080 上冒充 Prism 的两个接口：

  GET  /api/bot/status            → 机器人状态
  POST /api/ai/chat               → SSE 流（ai_chunk / ai_tool_done / ai_done）

用途：让**真实的**被控端（exe / python / APK 的逻辑）有一条可跑的完整链路，
      不用等到真 Prism 装好才能验收。

用法：python tools/fake_prism.py [port]
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

TOOL_RESULT = {
    "packets": [
        {"seq": 1, "packet_type": "Login", "direction": "in", "size": 64},
        {"seq": 2, "packet_type": "Text", "direction": "out", "size": 32},
    ]
}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        sys.stderr.write("[fake-prism] %s %s\n" % (self.command, self.path))

    def _json(self, obj):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _sse(self, text, tool=None):
        # ★ 必须用 chunked：被控端是 resp.read(4096) 读流的，
        #   如果既不给 Content-Length 又挂 keep-alive，read 会一直等 4096 字节
        #   或 EOF，短回复直接卡死（我第一版就是这么把测试拖超时的）。
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(b: bytes):
            if not b:
                return
            self.wfile.write(("%x\r\n" % len(b)).encode() + b + b"\r\n")
            self.wfile.flush()

        def ev(name, data):
            payload = json.dumps(data, ensure_ascii=False)
            chunk(f"event: {name}\ndata: {payload}\n\n".encode("utf-8"))

        try:
            # 逐字吐，模拟打字机
            for ch in text:
                ev("ai_chunk", {"text": ch})
                time.sleep(0.005)
            if tool:
                ev("ai_tool_start", {"name": tool})
                time.sleep(0.05)
                ev("ai_tool_done", {
                    "name": tool,
                    "result": json.dumps(TOOL_RESULT, ensure_ascii=False),
                    "evidence": "executed",
                })
            ev("ai_usage", {"input": 12, "output": len(text)})
            ev("ai_done", {"ok": True})
            self.wfile.write(b"0\r\n\r\n")   # 终止块
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True

    # ---------------- GET ----------------
    def do_GET(self):
        if self.path.startswith("/api/bot/status"):
            return self._json({
                "connected": True,
                "server": "假服务器",
                "bot_count": 1,
                "uptime_sec": 123,
            })
        if self.path.startswith("/api/ai/models"):
            return self._json({"models": ["prism自动", "gpt-4o"]})
        if self.path.startswith("/api/plugin/list"):
            return self._json({"plugins": ["ai_assist", "packet_capture"]})
        return self._json({"ok": True, "path": self.path})

    # ---------------- POST ----------------
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else "{}"
        try:
            body = json.loads(raw)
        except Exception:
            body = {}

        if self.path.startswith("/api/ai/chat"):
            msgs = body.get("messages") or []
            last_user = ""
            for m in reversed(msgs):
                if m.get("role") == "user":
                    last_user = m.get("content", "")
                    break
            # 被控端驱动工具时会带「只调用这一个工具」——识别出来就吐工具结果
            mt = re.search(r"请立即调用工具\s+`([^`]+)`", last_user)
            if mt:
                return self._sse(f"（假 Prism）已执行工具 {mt.group(1)}。", tool=mt.group(1))
            return self._sse(f"（假 Prism）收到：{last_user[:60]}")

        return self._json({"ok": True, "path": self.path, "echo": body})


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"假 Prism 已启动：http://127.0.0.1:{PORT}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass

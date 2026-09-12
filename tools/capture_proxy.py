#!/usr/bin/env python3
"""
============================================================
提示词捕获代理（本地验证版）
把 Prism 的模型 BaseURL 指向本代理，即可看到最终完整 prompt
============================================================
用法：
  1. 运行：python capture_proxy.py
  2. 在 Prism「模型设置」里把 BaseURL 改成 http://127.0.0.1:8787
  3. 在 Prism 里发一条 AI 消息
  4. 完整 prompt 会保存到 captured_prompts/ 目录
============================================================
"""
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

UPSTREAM = "https://prism.adblanlu.qzz.io/api/prism/ai"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "captured_prompts")
PORT = 8787

os.makedirs(OUT_DIR, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # 静音

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)

        # ★ 保存完整请求体
        ts = time.strftime("%Y%m%d_%H%M%S")
        try:
            body = json.loads(raw)
            path = os.path.join(OUT_DIR, f"prompt_{ts}.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(body, f, ensure_ascii=False, indent=2)

            msgs = body.get("messages", [])
            print(f"\n{'='*60}")
            print(f"★ 捕获到请求 -> {path}")
            print(f"{'='*60}")
            for m in msgs:
                role = m.get("role", "?")
                content = m.get("content", "")
                if isinstance(content, list):
                    content = json.dumps(content, ensure_ascii=False)
                print(f"\n--- role={role} (长度 {len(str(content))}) ---")
                print(str(content)[:2000])
                if len(str(content)) > 2000:
                    print(f"... [截断，共 {len(str(content))} 字符]")
            print(f"\n{'='*60}\n")
        except Exception as e:
            print(f"保存失败: {e}")
            path = os.path.join(OUT_DIR, f"raw_{ts}.bin")
            with open(path, "wb") as f:
                f.write(raw)

        # 转发到上游
        req = urllib.request.Request(
            UPSTREAM,
            data=raw,
            headers={
                "Content-Type": self.headers.get("Content-Type", "application/json"),
                "Authorization": self.headers.get("Authorization", ""),
                "Accept": self.headers.get("Accept", "text/event-stream"),
                "User-Agent": self.headers.get("User-Agent", "capture-proxy"),
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ("transfer-encoding", "connection"):
                        continue
                    self.send_header(k, v)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                while True:
                    chunk = resp.read(1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except Exception as e:
            print(f"上游请求失败: {e}")
            self.send_response(502)
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"service":"prompt-capture-proxy"}')

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()


if __name__ == "__main__":
    print(f"提示词捕获代理启动: http://127.0.0.1:{PORT}")
    print(f"上游: {UPSTREAM}")
    print(f"捕获目录: {OUT_DIR}")
    print("在 Prism「模型设置」里把 BaseURL 改成 http://127.0.0.1:8787 即可捕获\n")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

#!/usr/bin/env python3
"""NewGate 故障注入假上游。MODE 环境变量选行为；单端口。
MODE: ok | err500 | err403 | err429 | bigstream
"""
import json, os, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MODE", "ok")
PORT = int(os.environ.get("PORT", "9990"))

# 在途请求计数：断连后网关应立即拆掉上游连接，本计数随之归零。
# 若网关泄漏 producer 协程（仍在读上游），bigstream handler 不会退出，计数停在 >0——据此断言无残留。
_inflight = 0
_lock = threading.Lock()


def _enter():
    global _inflight
    with _lock:
        _inflight += 1


def _exit():
    global _inflight
    with _lock:
        _inflight -= 1


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        # GET /inflight → 当前在途请求数（供 harness 轮询断连后归零）
        if self.path == "/inflight":
            with _lock:
                n = _inflight
            self._json(200, {"inflight": n})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        _enter()
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 2) or "{}")
            stream = bool(body.get("stream"))
            if MODE == "err500":
                self._json(500, {"error": "upstream down"}); return
            if MODE == "err403":
                self._json(403, {"error": "forbidden"}); return
            if MODE == "err429":
                self._json(429, {"error": "rate limited"}); return
            if MODE == "bigstream":
                self._bigstream(); return
            if MODE == "midabort":
                self._midabort(); return
            # ok
            if stream:
                self._okstream(body.get("model", "?"))
            else:
                self._json(200, {
                    "id": "r1", "object": "chat.completion", "model": body.get("model", "?"),
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "hi"}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 1000, "completion_tokens": 500, "total_tokens": 1500},
                })
        finally:
            _exit()

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _okstream(self, model):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for i in range(3):
            c = {"choices": [{"delta": {"content": f"t{i} "}}]}
            self.wfile.write(f"data: {json.dumps(c)}\n\n".encode()); self.wfile.flush(); time.sleep(0.15)
        tail = {"choices": [], "usage": {"prompt_tokens": 1000, "completion_tokens": 500}}
        self.wfile.write(f"data: {json.dumps(tail)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()

    def _midabort(self):
        # 上游中途断流：发 2 个 SSE 块后强行关闭连接（不发 usage/[DONE]），模拟上游 midstream abort
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for i in range(2):
            self.wfile.write(f"data: {json.dumps({'choices':[{'delta':{'content':f't{i} '}}]})}\n\n".encode())
            self.wfile.flush(); time.sleep(0.1)
        self.close_connection = True
        try:
            self.connection.close()
        except Exception:
            pass

    def _bigstream(self):
        # 大块填满 socket 缓冲，客户端断连后下一次 write 立即失败（触发断连检测）
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        pad = "x" * 200000
        for i in range(30):
            try:
                self.wfile.write(f"data: {json.dumps({'choices':[{'delta':{'content':pad}}]})}\n\n".encode())
                self.wfile.flush()
            except Exception:
                return
            time.sleep(0.3)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

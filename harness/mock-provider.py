#!/usr/bin/env python3
"""模拟上游厂商（端到端演练用，不是故障注入）：一个端口同时说 OpenAI、Anthropic、Gemini 三种协议。

每个模型返回固定的 token 用量（USAGE 表），演练脚本据此精确核对扣费；校验网关转发来的上游 Key
（EXPECT_KEY），不对就 401；FAIL=1 时所有推理请求返回 500，用来演练故障切换。

GET /_stats  → 本实例各路径的命中数与最近一次请求体（演练脚本据此核对模型映射与透传的参数）
GET /_reset  → 清空统计

环境变量：PORT（缺省 19001）、NAME（出现在响应头 X-Mock-Upstream 与回复文本里）、EXPECT_KEY、FAIL
"""
import json, os, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "19001"))
NAME = os.environ.get("NAME", "mock")
EXPECT_KEY = os.environ.get("EXPECT_KEY", "")
FAIL = os.environ.get("FAIL", "") == "1"

# 模型 → (输入 tokens, 输出 tokens, 缓存读 tokens)。未列出的模型用 DEFAULT。
USAGE = {
    "gpt-4o-mini": (1200, 300, 0),
    "gpt-4.1": (2000, 500, 0),
    "claude-sonnet-4": (1500, 400, 0),
    "gemini-2.5-flash": (1000, 250, 0),
    "text-embedding-3-small": (64, 0, 0),
}
DEFAULT = (100, 50, 0)

_lock = threading.Lock()
_stats = {"hits": {}, "last": {}}


def usage_of(model):
    return USAGE.get(model, DEFAULT)


def reply_text(model):
    return f"Hello from {NAME} ({model})."


class Server(ThreadingHTTPServer):
    request_queue_size = 128
    daemon_threads = True


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    # ── 工具 ──
    def _send(self, code, obj, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Mock-Upstream", NAME)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _sse_start(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Mock-Upstream", NAME)
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def _sse(self, data, event=None):
        chunk = (f"event: {event}\n" if event else "") + f"data: {data if isinstance(data, str) else json.dumps(data)}\n\n"
        self.wfile.write(chunk.encode())
        self.wfile.flush()

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except Exception:
            return {}

    def _record(self, path, body):
        with _lock:
            _stats["hits"][path] = _stats["hits"].get(path, 0) + 1
            _stats["last"][path] = {"body": body, "headers": {k.lower(): v for k, v in self.headers.items() if k.lower() in ("authorization", "x-api-key", "x-goog-api-key", "anthropic-version", "user-agent")}}

    def _key_ok(self, key):
        return not EXPECT_KEY or key == EXPECT_KEY

    # ── 路由 ──
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/_stats":
            with _lock:
                self._send(200, _stats)
            return
        if u.path == "/_reset":
            with _lock:
                _stats["hits"].clear(); _stats["last"].clear()
            self._send(200, {"ok": True})
            return
        if u.path == "/v1/models":
            auth = self.headers.get("Authorization", "")
            if not self._key_ok(auth.removeprefix("Bearer ").strip()):
                self._send(401, {"error": {"message": "invalid api key", "type": "invalid_request_error"}}); return
            self._send(200, {"object": "list", "data": [{"id": m, "object": "model", "owned_by": NAME} for m in USAGE]})
            return
        self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        u = urlparse(self.path)
        body = self._body()
        self._record(u.path, body)
        if u.path in ("/v1/chat/completions", "/v1/embeddings"):
            key = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            if not self._key_ok(key):
                self._send(401, {"error": {"message": "invalid api key", "type": "invalid_request_error"}}); return
            if FAIL:
                self._send(500, {"error": {"message": f"{NAME} is down", "type": "server_error"}}); return
            return self._openai_embeddings(body) if u.path.endswith("embeddings") else self._openai_chat(body)
        if u.path == "/v1/messages":
            if not self._key_ok(self.headers.get("x-api-key", "")):
                self._send(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}); return
            if FAIL:
                self._send(500, {"type": "error", "error": {"type": "api_error", "message": f"{NAME} is down"}}); return
            return self._anthropic(body)
        m = re.match(r"^/v1beta/models/([^:/]+):(generateContent|streamGenerateContent)$", u.path)
        if m:
            key = self.headers.get("x-goog-api-key") or parse_qs(u.query).get("key", [""])[0]
            if not self._key_ok(key):
                self._send(401, {"error": {"code": 401, "message": "API key not valid", "status": "UNAUTHENTICATED"}}); return
            if FAIL:
                self._send(500, {"error": {"code": 500, "message": f"{NAME} is down", "status": "INTERNAL"}}); return
            return self._gemini(m.group(1), stream=m.group(2) == "streamGenerateContent")
        self._send(404, {"error": {"message": f"no route {u.path}"}})

    # ── OpenAI ──
    def _openai_chat(self, body):
        model = body.get("model", "")
        pin, pout, pcache = usage_of(model)
        text = reply_text(model)
        usage = {"prompt_tokens": pin, "completion_tokens": pout, "total_tokens": pin + pout,
                 "prompt_tokens_details": {"cached_tokens": pcache}}
        cid = f"chatcmpl-{NAME}-{int(time.time() * 1000)}"
        if not body.get("stream"):
            self._send(200, {"id": cid, "object": "chat.completion", "created": int(time.time()), "model": model,
                             "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
                             "usage": usage})
            return
        self._sse_start()
        base = {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()), "model": model}
        self._sse({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]})
        for word in text.split(" "):
            self._sse({**base, "choices": [{"index": 0, "delta": {"content": word + " "}, "finish_reason": None}]})
            time.sleep(0.02)
        self._sse({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        # 与 OpenAI 一致：只有请求带 stream_options.include_usage 才在最后单独发一块用量
        if (body.get("stream_options") or {}).get("include_usage"):
            self._sse({**base, "choices": [], "usage": usage})
        self._sse("[DONE]")

    def _openai_embeddings(self, body):
        model = body.get("model", "")
        pin = usage_of(model)[0]
        inputs = body.get("input")
        n = len(inputs) if isinstance(inputs, list) else 1
        self._send(200, {"object": "list", "model": model,
                         "data": [{"object": "embedding", "index": i, "embedding": [0.1, 0.2, 0.3]} for i in range(n)],
                         "usage": {"prompt_tokens": pin, "total_tokens": pin}})

    # ── Anthropic ──
    def _anthropic(self, body):
        model = body.get("model", "")
        pin, pout, pcache = usage_of(model)
        text = reply_text(model)
        mid = f"msg_{NAME}_{int(time.time() * 1000)}"
        if not body.get("stream"):
            self._send(200, {"id": mid, "type": "message", "role": "assistant", "model": model,
                             "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None,
                             "usage": {"input_tokens": pin, "output_tokens": pout, "cache_read_input_tokens": pcache, "cache_creation_input_tokens": 0}})
            return
        self._sse_start()
        self._sse({"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant", "model": model, "content": [],
                   "stop_reason": None, "usage": {"input_tokens": pin, "output_tokens": 1, "cache_read_input_tokens": pcache, "cache_creation_input_tokens": 0}}}, "message_start")
        self._sse({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}, "content_block_start")
        for word in text.split(" "):
            self._sse({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": word + " "}}, "content_block_delta")
            time.sleep(0.02)
        self._sse({"type": "content_block_stop", "index": 0}, "content_block_stop")
        self._sse({"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": pout}}, "message_delta")
        self._sse({"type": "message_stop"}, "message_stop")

    # ── Gemini ──
    def _gemini(self, model, stream):
        pin, pout, pcache = usage_of(model)
        text = reply_text(model)
        usage = {"promptTokenCount": pin, "candidatesTokenCount": pout, "totalTokenCount": pin + pout, "cachedContentTokenCount": pcache}
        if not stream:
            self._send(200, {"candidates": [{"content": {"role": "model", "parts": [{"text": text}]}, "finishReason": "STOP", "index": 0}],
                             "usageMetadata": usage, "modelVersion": model})
            return
        self._sse_start()
        words = text.split(" ")
        for i, word in enumerate(words):
            last = i == len(words) - 1
            chunk = {"candidates": [{"content": {"role": "model", "parts": [{"text": word + ("" if last else " ")}]}, "index": 0,
                                     **({"finishReason": "STOP"} if last else {})}], "modelVersion": model}
            # Gemini 的流里每块都带累计用量，最后一块是终值
            chunk["usageMetadata"] = usage if last else {"promptTokenCount": pin, "totalTokenCount": pin}
            self._sse(chunk)
            time.sleep(0.02)


if __name__ == "__main__":
    Server(("127.0.0.1", PORT), H).serve_forever()

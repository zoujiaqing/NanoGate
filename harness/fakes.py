#!/usr/bin/env python3
"""NewGate 故障注入假上游。MODE 环境变量选行为；单端口。
MODE: ok | slowok | err500 | err403 | err429 | bigstream | midabort | embok | azure | tools | rerank | bedrock | vertex
"""
import json, os, time, threading, hashlib, hmac, base64, struct, zlib, datetime
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
        if self.path == "/prices.json":
            # 价源同步用的价目表（对象形状）
            self._json(200, {"sync-a": {"input": 1.5, "output": 6, "maxOutput": 4096}, "sync-b": {"inputPrice": "0.2", "outputPrice": "0.8"}})
            return
        if self.path == "/v1/models":
            # 上游模型清单（渠道「拉取模型」用）；顺带把鉴权头回显，harness 据此断言走的是渠道的 Key
            self._json(200, {"object": "list", "data": [{"id": "m-list-b"}, {"id": "m-list-a"}], "auth": self.headers.get("Authorization")})
            return
        if self.path == "/inflight":
            with _lock:
                n = _inflight
            self._json(200, {"inflight": n})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        _enter()
        try:
            self._raw_body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = json.loads(self._raw_body or b"{}")
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
            if MODE == "slowok":
                # 慢响应：拖长首响应时间，制造「请求在途」窗口（供在途改价等场景）
                time.sleep(float(os.environ.get("SLOW_DELAY", "2")))
                self._json(200, {
                    "id": "r1", "object": "chat.completion", "model": body.get("model", "?"),
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "hi"}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 1000, "completion_tokens": 500, "total_tokens": 1500},
                }); return
            if MODE == "bedrock":
                self._bedrock(body); return
            if MODE == "vertex":
                self._vertex(body); return
            if MODE == "tools":
                if os.environ.get("FAKE_DUMP"):
                    with open(os.environ["FAKE_DUMP"], "a") as fh: fh.write(json.dumps({"headers": dict(self.headers), "body": body}) + "\n")
                # 工具调用 + reasoning_content：第一轮回 tool_calls；请求里已带 tool 结果则回文本
                has_result = any(m.get("role") == "tool" for m in body.get("messages", []))
                if not stream:
                    if has_result:
                        msg = {"role": "assistant", "content": "done: " + str([m.get("content") for m in body["messages"] if m.get("role") == "tool"]), "reasoning_content": "checked"}
                        fin = "stop"
                    else:
                        msg = {"role": "assistant", "content": None, "reasoning_content": "need tool",
                               "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"a.txt\"}"}}]}
                        fin = "tool_calls"
                    self._json(200, {"id": "r1", "object": "chat.completion", "model": body.get("model", "?"),
                                     "choices": [{"index": 0, "message": msg, "finish_reason": fin}],
                                     "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120, "prompt_tokens_details": {"cached_tokens": 40}}}); return
                self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
                def w(d):
                    self.wfile.write(f"data: {json.dumps(d)}\n\n".encode()); self.wfile.flush()
                if has_result:
                    w({"choices": [{"index": 0, "delta": {"role": "assistant", "reasoning_content": "checked"}, "finish_reason": None}]})
                    w({"choices": [{"index": 0, "delta": {"content": "done"}, "finish_reason": "stop"}]})
                    w({"choices": [], "usage": {"prompt_tokens": 120, "completion_tokens": 5}})
                    self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush(); return
                w({"choices": [{"index": 0, "delta": {"role": "assistant", "reasoning_content": "need "}, "finish_reason": None}]})
                w({"choices": [{"index": 0, "delta": {"reasoning_content": "tool"}, "finish_reason": None}]})
                w({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":"}}]}, "finish_reason": None}]})
                w({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "\"a.txt\"}"}}]}, "finish_reason": "tool_calls"}]})
                w({"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20, "prompt_tokens_details": {"cached_tokens": 40}}})
                self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush(); return
            if MODE == "azure":
                # Azure OpenAI 形状校验：api-key 头 + /openai/deployments/<dep>/chat/completions?api-version=…
                # 不满足就 400 并把实际收到的东西回给 harness，断言失败时能直接看到差在哪。
                dep = os.environ.get("AZURE_DEPLOYMENT", "dep-1")
                want = f"/openai/deployments/{dep}/chat/completions?api-version=2024-06-01"
                if self.headers.get("api-key") != os.environ.get("AZURE_KEY", "sk-azure") or self.headers.get("Authorization") or self.path != want:
                    self._json(400, {"error": {"message": f"bad azure request path={self.path} api-key={self.headers.get('api-key')} auth={self.headers.get('Authorization')}"}}); return
                self._json(200, {
                    "id": "r1", "object": "chat.completion", "model": body.get("model", "?"),
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "hi"}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
                }); return
            if MODE == "embok":
                # embeddings 响应：usage 只有 prompt_tokens（没有 completion）——计费不得凭空补出输出 tokens
                self._json(200, {
                    "object": "list",
                    "data": [{"object": "embedding", "index": 0, "embedding": [0.01, -0.02, 0.03]}],
                    "model": body.get("model", "?"),
                    "usage": {"prompt_tokens": 7, "total_tokens": 7},
                }); return
            if self.path == "/v1/rerank":
                # Jina / Cohere 形状：results + usage.total_tokens（没有 prompt/completion 之分）
                docs = body.get("documents", [])
                self._json(200, {"model": body.get("model", "?"), "results": [{"index": i, "relevance_score": 0.9 - i * 0.1} for i in range(len(docs))],
                                 "usage": {"total_tokens": 77}}); return
            if self.path == "/v1/images/generations":
                # DALL·E 形状：没有 usage，网关只能按次计价
                self._json(200, {"created": 1, "data": [{"url": "http://127.0.0.1/x.png", "revised_prompt": body.get("prompt", "")}]}); return
            if self.path == "/v1/responses":
                # Responses API：不认 stream_options（真上游会 400，这里也照样 400 好让网关的注入露馅）
                if "stream_options" in body:
                    self._json(400, {"error": {"message": "Unknown parameter: 'stream_options'"}}); return
                self._responses(body.get("model", "?"), stream); return
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

    def _responses(self, model, stream):
        usage = {"input_tokens": 1000, "output_tokens": 500, "total_tokens": 1500}
        if not stream:
            self._json(200, {"id": "resp_1", "object": "response", "model": model, "status": "completed",
                             "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "hi"}]}],
                             "usage": usage}); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def ev(name, obj):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(obj)}\n\n".encode()); self.wfile.flush()
        ev("response.created", {"type": "response.created", "response": {"id": "resp_1", "model": model, "status": "in_progress"}})
        for i in range(3):
            ev("response.output_text.delta", {"type": "response.output_text.delta", "delta": f"t{i} "}); time.sleep(0.1)
        ev("response.completed", {"type": "response.completed", "response": {"id": "resp_1", "model": model, "status": "completed", "usage": usage}})

    # ── Bedrock：校验 SigV4（用已知的 AK/SK 重算签名）+ 路径；非流式回 Anthropic JSON，流式回 event-stream 二进制帧 ──
    def _sigv4_expected(self, raw_body):
        ak, sk = "AKIAFAKE", "fakesecret"
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("AWS4-HMAC-SHA256 "): return "missing sigv4: " + auth[:40]
        parts = dict(kv.strip().split("=", 1) for kv in auth[len("AWS4-HMAC-SHA256 "):].split(","))
        cred = parts["Credential"]; signed_headers = parts["SignedHeaders"]
        _, date, region, service, _ = cred.split("/")
        amz_date = self.headers.get("X-Amz-Date", "")
        canon_headers = "".join(f"{h}:{' '.join(self.headers.get(h, '').split())}\n" for h in signed_headers.split(";"))
        path = self.path.split("?")[0]
        canon_uri = "/".join(seg.replace("%", "%25").replace(":", "%3A") for seg in path.split("/"))
        payload_hash = hashlib.sha256(raw_body).hexdigest()
        canonical = "\n".join(["POST", canon_uri, "", canon_headers, signed_headers, payload_hash])
        scope = f"{date}/{region}/{service}/aws4_request"
        sts = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        k = ("AWS4" + sk).encode()
        for v in (date, region, service, "aws4_request"): k = hmac.new(k, v.encode(), hashlib.sha256).digest()
        sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
        if parts["Signature"] != sig: return f"bad signature (expected {sig[:12]}…, got {parts['Signature'][:12]}…; canonical={canonical!r})"
        if not cred.startswith(ak + "/"): return "bad access key"
        return None

    def _bedrock(self, body):
        raw = self._raw_body
        err = self._sigv4_expected(raw)
        if err: self._json(403, {"message": err}); return
        if body.get("anthropic_version") != "bedrock-2023-05-31" or "model" in body or "stream" in body:
            self._json(400, {"message": f"bad body keys: {sorted(body.keys())}"}); return
        dep = os.environ.get("BEDROCK_MODEL", "anthropic.claude-3-5-sonnet-20241022-v2:0")
        want_base = "/model/" + dep.replace(":", "%3A") + "/"
        if not self.path.startswith(want_base): self._json(404, {"message": f"bad path {self.path}, want {want_base}..."}); return
        if self.path.endswith("/invoke"):
            self._json(200, {"id": "msg_b", "type": "message", "role": "assistant", "model": "claude-3-5-sonnet", "content": [{"type": "text", "text": "from bedrock"}],
                             "stop_reason": "end_turn", "usage": {"input_tokens": 11, "output_tokens": 4}}); return
        # invoke-with-response-stream：AWS event-stream 帧
        self.send_response(200); self.send_header("Content-Type", "application/vnd.amazon.eventstream"); self.end_headers()
        def frame(headers, payload):
            hb = b""
            for k, v in headers.items():
                kb, vb = k.encode(), v.encode(); hb += bytes([len(kb)]) + kb + b"\x07" + struct.pack(">H", len(vb)) + vb
            total = 12 + len(hb) + len(payload) + 4
            prelude = struct.pack(">II", total, len(hb))
            msg = prelude + struct.pack(">I", zlib.crc32(prelude)) + hb + payload
            return msg + struct.pack(">I", zlib.crc32(msg))
        def chunk(ev):
            return frame({":message-type": "event", ":event-type": "chunk", ":content-type": "application/json"},
                         json.dumps({"bytes": base64.b64encode(json.dumps(ev).encode()).decode()}).encode())
        events = [
            {"type": "message_start", "message": {"id": "msg_b", "type": "message", "role": "assistant", "model": "claude-3-5-sonnet", "content": [], "usage": {"input_tokens": 11, "output_tokens": 0}}},
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "from "}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "bedrock"}},
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 4}},
            {"type": "message_stop", "amazon-bedrock-invocationMetrics": {"inputTokenCount": 11, "outputTokenCount": 4}},
        ]
        data = b"".join(chunk(e) for e in events)
        # 故意按奇怪边界切着发，逼解码器处理跨包帧
        for i in range(0, len(data), 37):
            self.wfile.write(data[i:i + 37]); self.wfile.flush(); time.sleep(0.01)

    # ── Vertex：Bearer + 路径形状；anthropic 发布者回 Anthropic JSON，google 发布者回 Gemini JSON ──
    def _vertex(self, body):
        if self.headers.get("Authorization") != "Bearer vtx-token": self._json(401, {"error": {"message": "bad bearer " + self.headers.get("Authorization", "")}}); return
        want = "/v1/projects/proj-x/locations/us-east5/publishers/"
        if not self.path.startswith(want): self._json(404, {"error": {"message": f"bad path {self.path}"}}); return
        rest = self.path[len(want):]
        if rest.startswith("anthropic/models/"):
            if body.get("anthropic_version") != "vertex-2023-10-16" or "model" in body: self._json(400, {"error": {"message": f"bad body keys {sorted(body.keys())}"}}); return
            if rest.endswith(":rawPredict"):
                self._json(200, {"id": "msg_v", "type": "message", "role": "assistant", "model": "claude", "content": [{"type": "text", "text": "from vertex"}], "stop_reason": "end_turn", "usage": {"input_tokens": 5, "output_tokens": 2}}); return
            self._json(400, {"error": {"message": "stream not faked"}}); return
        if rest.startswith("google/models/") and rest.endswith(":generateContent"):
            self._json(200, {"candidates": [{"content": {"parts": [{"text": "from vertex gemini"}], "role": "model"}, "finishReason": "STOP", "index": 0}],
                             "usageMetadata": {"promptTokenCount": 6, "candidatesTokenCount": 3, "totalTokenCount": 9}}); return
        self._json(404, {"error": {"message": f"unknown publisher path {rest}"}})

    def _okstream(self, model):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for i in range(3):
            c = {"model": model, "choices": [{"delta": {"content": f"t{i} "}}]}
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

#!/usr/bin/env python3
"""演示用上游：OpenAI 兼容（chat 非流式 / 流式、embeddings、/v1/models），用量随机但像真实流量。

只给 harness/demo 灌演示数据用：输入几百到几千 tokens、输出一两百到一千多，偶尔带缓存命中。
用法：PORT=9850 python3 demo-upstream.py
"""
import json, os, random, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "9850"))
REPLY = "这是演示环境的回答：NetonAPI 按官方价计费，每一笔都能对账。"


def usage_for(model):
    heavy = any(k in model for k in ("opus", "pro", "o3", "gpt-5", "max", "k3"))
    prompt = random.randint(400, 9000 if heavy else 4000)
    completion = random.randint(80, 1800 if heavy else 900)
    cached = random.choice([0, 0, 0, int(prompt * random.uniform(0.3, 0.8))])
    return {"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
            "prompt_tokens_details": {"cached_tokens": cached}}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            return self._json(200, {"object": "list", "data": []})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        model = body.get("model", "model")
        time.sleep(random.uniform(0.05, 0.25))
        if self.path.endswith("/embeddings"):
            tokens = random.randint(50, 2000)
            return self._json(200, {"object": "list", "model": model,
                                    "data": [{"object": "embedding", "index": 0, "embedding": [0.01] * 8}],
                                    "usage": {"prompt_tokens": tokens, "total_tokens": tokens}})
        u = usage_for(model)
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for piece in (REPLY[:10], REPLY[10:]):
                chunk = {"id": "c1", "object": "chat.completion.chunk", "model": model,
                         "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode())
            end = {"id": "c1", "object": "chat.completion.chunk", "model": model,
                   "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(end)}\n\n".encode())
            self.wfile.write(f"data: {json.dumps({'id': 'c1', 'object': 'chat.completion.chunk', 'model': model, 'choices': [], 'usage': u})}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        self._json(200, {"id": "c1", "object": "chat.completion", "model": model,
                         "choices": [{"index": 0, "message": {"role": "assistant", "content": REPLY}, "finish_reason": "stop"}],
                         "usage": u})


if __name__ == "__main__":
    random.seed(int(os.environ.get("SEED", "7")))
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

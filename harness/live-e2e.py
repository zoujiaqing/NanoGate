#!/usr/bin/env python3
"""线上端到端演练：按真实用户的路径走一遍「管理员配渠道定价 → 用户充值建 Key → 三种协议调用 → 扣费对账」。

上游是部署在服务器本机的模拟厂商（harness/mock-provider.py）：
  mock-a  127.0.0.1:19001  正常，上游 Key sk-mock-a
  mock-b  127.0.0.1:19002  永远 500（故障切换演练），上游 Key sk-mock-b
后端需开 NETONAPI_ENABLE_MOCK_RECHARGE=true，出站放行 127.0.0.1 与这两个端口。

环境变量：
  ADMIN_URL（缺省 https://admin.neton.cloud）、API_URL（缺省 https://api.neton.cloud）
  ADMIN_USER / ADMIN_PASSWORD、MEMBER_USER / MEMBER_PASSWORD
  MOCK_STATS_CMD：取 mock 统计的命令前缀（如 "ssh … root@host"），设了才核对上游侧
只建 / 改名字以 e2e- 开头的渠道与 Key，跑完删掉本次建的 Key；渠道与价格保留，下次覆盖。
"""
import json, os, shlex, ssl, subprocess, sys, time, urllib.error, urllib.request

ADMIN = os.environ.get("ADMIN_URL", "https://admin.neton.cloud").rstrip("/")
API = os.environ.get("API_URL", "https://api.neton.cloud").rstrip("/")
CTX = ssl.create_default_context()
RESULTS = []

# 价格（USD / 1M tokens）与模拟上游的固定用量（与 mock-provider.py 的 USAGE 一致）
PRICES = {
    "gpt-4o-mini": ("0.15", "0.6"),
    "gpt-4.1": ("2", "8"),
    "claude-sonnet-4": ("3", "15"),
    "gemini-2.5-flash": ("0.3", "2.5"),
    "text-embedding-3-small": ("0.02", "0"),
}
DEFAULT_CAP = 4096
USAGE = {"gpt-4o-mini": (1200, 300), "gpt-4.1": (2000, 500), "claude-sonnet-4": (1500, 400),
         "gemini-2.5-flash": (1000, 250), "text-embedding-3-small": (64, 0)}


def jl(e):
    """SSE 的一条 data：JSON 就解析，否则 None（[DONE]、错误文本）。"""
    try:
        return json.loads(e)
    except Exception:
        return None


def check(ok, name, detail=""):
    RESULTS.append((bool(ok), name, detail))
    print(("  ✅ " if ok else "  ❌ ") + name + (f"  [{detail}]" if detail and not ok else ""), flush=True)
    return ok


def http(method, url, body=None, headers=None, stream=False, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": "netonapi-live-e2e"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        r = urllib.request.urlopen(req, context=CTX, timeout=timeout)
        status, rh = r.status, dict(r.headers)
        raw = r.read() if not stream else r
    except urllib.error.HTTPError as e:
        status, rh, raw = e.code, dict(e.headers), e.read()
        stream = False
    if stream:
        events, text = [], b""
        for line in raw:
            text += line
            line = line.decode().strip()
            if line.startswith("data:"):
                events.append(line[5:].strip())
        return status, rh, events
    try:
        return status, rh, json.loads(raw or b"null")
    except Exception:
        return status, rh, raw.decode(errors="replace")


def ok_data(resp, what):
    status, _, body = resp
    if status != 200 or not isinstance(body, dict) or body.get("code") != 0:
        raise SystemExit(f"{what} failed: http={status} body={str(body)[:300]}")
    return body.get("data")


def admin(method, path, body=None):
    return ok_data(http(method, f"{ADMIN}/admin{path}", body, {"Authorization": f"Bearer {ATOK}"}), f"admin {method} {path}")


def app(method, path, body=None, tok=None):
    return http(method, f"{ADMIN}/app{path}", body, {"Authorization": f"Bearer {tok or MTOK}"})


def mock_stats(port):
    cmd = os.environ.get("MOCK_STATS_CMD")
    if not cmd:
        return None
    out = subprocess.run(shlex.split(cmd) + [f"curl -s -m 5 http://127.0.0.1:{port}/_stats"], capture_output=True, text=True, timeout=30).stdout
    return json.loads(out or "{}")


def mock_reset(port):
    cmd = os.environ.get("MOCK_STATS_CMD")
    if cmd:
        subprocess.run(shlex.split(cmd) + [f"curl -s -m 5 http://127.0.0.1:{port}/_reset"], capture_output=True, timeout=30)


def micro(price, tokens):
    """tokens × USD/1M → μUSD（整数，四舍五入；与后端整数计价同一口径的近似，用于±1 容差比对）"""
    whole, _, frac = price.partition(".")
    p = int(whole) * 10**6 + int((frac + "000000")[:6])  # μUSD / 1M tokens
    return (tokens * p + 500_000) // 1_000_000


# ════════════════════════ 准备：管理员 ════════════════════════
print("[setup] 管理员登录、渠道、定价")
ATOK = ok_data(http("POST", f"{ADMIN}/admin/system/auth/login", {"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASSWORD"]}), "admin login")["accessToken"]

existing = admin("GET", "/gateway/channel/list")
existing = existing.get("list", existing) if isinstance(existing, dict) else existing
for ch in existing:
    if ch["name"].startswith("e2e-"):
        admin("DELETE", f"/gateway/channel/delete/{ch['id']}")

CHANNELS = [
    # 优先级高的先用：备份线路（mock-b，永远 500）排在前面，演练失败后切到 mock-a
    ("e2e-openai-flaky", "openai_compatible", "http://127.0.0.1:19002", "gpt-4o-mini,gpt-4.1,text-embedding-3-small", "chat,embeddings", 10, "sk-mock-b"),
    ("e2e-openai", "openai_compatible", "http://127.0.0.1:19001", "gpt-4o-mini,gpt-4.1,text-embedding-3-small", "chat,embeddings", 5, "sk-mock-a"),
    ("e2e-anthropic", "anthropic", "http://127.0.0.1:19001", "claude-sonnet-4", "chat", 5, "sk-mock-a"),
    ("e2e-gemini", "gemini", "http://127.0.0.1:19001", "gemini-2.5-flash", "chat", 5, "sk-mock-a"),
]
for name, typ, url, models, caps, prio, key in CHANNELS:
    admin("POST", "/gateway/channel/create", {"name": name, "type": typ, "baseUrl": url, "models": models, "capabilities": caps,
                                               "priority": prio, "weight": 1, "costDiscount": "0.6", "keys": [key], "status": 1})
check(True, "建渠道：OpenAI 兼容 ×2（一条故障）、Anthropic、Gemini")

prices = {p["model"]: p for p in admin("GET", "/gateway/price/list")}
for model, (pin, pout) in PRICES.items():
    # 对话模型配默认输出上限（请求不带 max_tokens 时预扣与转发都用它）；向量模型不配——它不产生输出
    cap = None if model.startswith("text-embedding") else DEFAULT_CAP
    body = {"model": model, "inputPrice": pin, "outputPrice": pout, "displayName": None, "defaultMaxOutputTokens": cap}
    if model in prices:
        admin("PUT", "/gateway/price/update", {**body, "id": prices[model]["id"]})
    else:
        admin("POST", "/gateway/price/create", body)
check(True, "定价：5 个模型")

# ════════════════════════ 用户：登录、充值、建 Key ════════════════════════
print("[member] 登录、模拟充值、兑换码、建 Key")
MTOK = ok_data(http("POST", f"{ADMIN}/app/auth/login-username", {"username": os.environ["MEMBER_USER"], "password": os.environ["MEMBER_PASSWORD"]}), "member login")["accessToken"]
bal0 = ok_data(app("GET", "/gateway/usage/balance"), "balance")
r = app("POST", "/gateway/recharge/mock", {"amount": 20_000_000})
bal1 = ok_data(app("GET", "/gateway/usage/balance"), "balance")
check(r[0] == 200 and bal1["balance"] - bal0["balance"] == 20_000_000, "模拟充值 $20 入账", f"{r[0]} {bal0} → {bal1}")

codes = admin("POST", "/gateway/redemption/generate", {"quotaMicro": 5_000_000, "count": 1, "note": "e2e"})
code = (codes.get("codes") if isinstance(codes, dict) else codes)[0]
code = code["code"] if isinstance(code, dict) else code
r = app("POST", "/gateway/redeem", {"code": code})
bal2 = ok_data(app("GET", "/gateway/usage/balance"), "balance")
check(r[0] == 200 and bal2["balance"] - bal1["balance"] == 5_000_000, "兑换码 $5 入账", f"{r[0]} {r[2]}")
r = app("POST", "/gateway/redeem", {"code": code})
check(r[0] != 200, "同一兑换码不能兑两次", f"{r[0]}")

catalog = {m["model"]: m for m in ok_data(app("GET", "/gateway/model/list"), "model list")}
check(all(m in catalog for m in PRICES), "用户模型目录里有 5 个模型", ",".join(sorted(catalog)))
SALE = {m: (catalog[m]["inputPrice"], catalog[m]["outputPrice"]) for m in PRICES if m in catalog}

for t in ok_data(app("GET", "/gateway/token/list"), "token list") or []:
    if str(t.get("name", "")).startswith("e2e-"):
        app("DELETE", f"/gateway/token/delete/{t['id']}")
created = ok_data(app("POST", "/gateway/token/create", {"name": "e2e-main", "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": ""}), "create token")
KEY = created.get("key") if isinstance(created, dict) else created
check(isinstance(KEY, str) and KEY.startswith("sk-"), "创建 API Key（只在创建时返回明文）", str(created)[:80])
created = ok_data(app("POST", "/gateway/token/create", {"name": "e2e-limited", "quotaBudget": 1000, "expiresAt": None, "allowedModels": "gpt-4o-mini", "allowedIps": ""}), "create limited token")
LKEY = created.get("key") if isinstance(created, dict) else created
listed = ok_data(app("GET", "/gateway/token/list"), "token list")
check(all(KEY not in json.dumps(t) for t in listed), "Key 列表里不出现明文")

# ════════════════════════ 调用 ════════════════════════
print("[call] 三种协议、流式与非流式")
for p in (19001, 19002):
    mock_reset(p)
OAI = {"Authorization": f"Bearer {KEY}"}
calls = []  # (model, stream)

s, h, b = http("GET", f"{API}/v1/models", headers=OAI)
ids = [m["id"] for m in (b.get("data") or [])] if isinstance(b, dict) else []
check(s == 200 and all(m in ids for m in PRICES), "GET /v1/models 列出可用模型", f"{s} {ids}")

s, h, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "hi"}]}, OAI)
txt = (b.get("choices") or [{}])[0].get("message", {}).get("content", "") if isinstance(b, dict) else ""
check(s == 200 and "mock-a" in txt, "OpenAI 非流式 gpt-4o-mini（故障线路失败后切到正常线路）", f"{s} {str(b)[:200]}")
check(isinstance(b, dict) and b.get("usage", {}).get("prompt_tokens") == 1200 and b["usage"].get("completion_tokens") == 300, "非流式返回的 usage 与上游一致", str(b.get("usage") if isinstance(b, dict) else b))
calls.append(("gpt-4o-mini", False))

s, h, ev = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "stream": True, "messages": [{"role": "user", "content": "hi"}]}, OAI, stream=True)
content = "".join(((jl(e).get("choices") or [{}])[0].get("delta") or {}).get("content") or "" for e in ev if isinstance(jl(e), dict))
check(s == 200 and ev and ev[-1] == "[DONE]" and "mock-a" in content, "OpenAI 流式 gpt-4o-mini：内容完整、以 [DONE] 结束", f"{s} events={len(ev)} content={content!r}")
calls.append(("gpt-4o-mini", True))

s, h, ev = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4.1", "stream": True, "stream_options": {"include_usage": True}, "messages": [{"role": "user", "content": "hi"}]}, OAI, stream=True)
usage_chunks = [jl(e)["usage"] for e in ev if isinstance(jl(e), dict) and jl(e).get("usage")]
check(s == 200 and usage_chunks and usage_chunks[-1].get("prompt_tokens") == 2000, "OpenAI 流式带 include_usage：最后一块是用量", f"{s} {usage_chunks}")
calls.append(("gpt-4.1", True))

s, h, b = http("POST", f"{API}/v1/embeddings", {"model": "text-embedding-3-small", "input": ["a", "b"]}, OAI)
check(s == 200 and isinstance(b, dict) and len(b.get("data") or []) == 2, "向量 embeddings", f"{s} {str(b)[:160]}")
calls.append(("text-embedding-3-small", False))

ANT = {"x-api-key": KEY, "anthropic-version": "2023-06-01"}
s, h, b = http("POST", f"{API}/v1/messages", {"model": "claude-sonnet-4", "max_tokens": 256, "messages": [{"role": "user", "content": "hi"}]}, ANT)
check(s == 200 and isinstance(b, dict) and "mock-a" in json.dumps(b.get("content")) and b.get("usage", {}).get("input_tokens") == 1500, "Anthropic 非流式 claude-sonnet-4", f"{s} {str(b)[:200]}")
calls.append(("claude-sonnet-4", False))
s, h, ev = http("POST", f"{API}/v1/messages", {"model": "claude-sonnet-4", "max_tokens": 256, "stream": True, "messages": [{"role": "user", "content": "hi"}]}, ANT, stream=True)
types = [jl(e).get("type") for e in ev if isinstance(jl(e), dict)]
check(s == 200 and types[:1] == ["message_start"] and types[-1:] == ["message_stop"], "Anthropic 流式：message_start … message_stop", f"{s} {types}")
calls.append(("claude-sonnet-4", True))

GEM = {"x-goog-api-key": KEY}
s, h, b = http("POST", f"{API}/v1beta/models/gemini-2.5-flash:generateContent", {"contents": [{"role": "user", "parts": [{"text": "hi"}]}]}, GEM)
check(s == 200 and isinstance(b, dict) and "mock-a" in json.dumps(b.get("candidates")) and b.get("usageMetadata", {}).get("promptTokenCount") == 1000, "Gemini 非流式 gemini-2.5-flash", f"{s} {str(b)[:200]}")
calls.append(("gemini-2.5-flash", False))
s, h, ev = http("POST", f"{API}/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse", {"contents": [{"role": "user", "parts": [{"text": "hi"}]}]}, GEM, stream=True)
gtext = "".join(p.get("text", "") for e in ev if isinstance(jl(e), dict) for c in jl(e).get("candidates", []) for p in c.get("content", {}).get("parts", []))
check(s == 200 and "mock-a" in gtext, "Gemini 流式", f"{s} {gtext!r}")
calls.append(("gemini-2.5-flash", True))

s, h, b = http("POST", f"{API}/v1/chat/completions", {"model": "claude-sonnet-4", "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s == 200 and isinstance(b, dict) and "mock-a" in json.dumps(b.get("choices")), "跨协议：用 OpenAI 格式调 Claude", f"{s} {str(b)[:200]}")
calls.append(("claude-sonnet-4", False))

print("[deny] 拒绝路径")
s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "hi"}]}, {"Authorization": "Bearer sk-not-a-real-key"})
check(s == 401, "无效 Key → 401", f"{s} {str(b)[:120]}")
s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "no-such-model", "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s in (400, 404), "不存在的模型 → 4xx", f"{s} {str(b)[:120]}")
LIM = {"Authorization": f"Bearer {LKEY}"}
s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4.1", "messages": [{"role": "user", "content": "hi"}]}, LIM)
check(s in (400, 403, 404), "Key 不允许的模型 → 拒绝", f"{s} {str(b)[:120]}")
limited_ok, limited_codes = 0, []
for _ in range(6):
    s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 300, "messages": [{"role": "user", "content": "hi"}]}, LIM)
    limited_codes.append(s)
    if s == 200:
        limited_ok += 1
    else:
        break
check(limited_ok >= 1 and limited_codes[-1] in (402, 403, 429), "Key 额度上限 $0.001：用完后拒绝", f"{limited_codes}")
calls += [("gpt-4o-mini", False)] * limited_ok

# 不带 max_tokens：预扣用模型默认上限，且这个上限必须真的发给上游（否则上游可多输出、结算超出预留）
s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4.1", "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s == 200, "不带 max_tokens 的请求可以调用（用模型默认输出上限）", f"{s} {str(b)[:160]}")
calls.append(("gpt-4.1", False))
st = mock_stats(19001)
if st is not None:
    sent = (st["last"].get("/v1/chat/completions") or {}).get("body") or {}
    check(sent.get("max_tokens") == DEFAULT_CAP or sent.get("max_completion_tokens") == DEFAULT_CAP,
          f"默认输出上限 {DEFAULT_CAP} 写进了转发给上游的请求", str({k: sent.get(k) for k in ("model", "max_tokens", "max_completion_tokens")}))

# ════════════════════════ 对账 ════════════════════════
print("[billing] 扣费对账")
time.sleep(3)
logs = ok_data(app("GET", "/gateway/usage/log/page?pageNo=1&pageSize=50"), "usage logs")["list"]
recent = logs[: len(calls)]
check(len(logs) >= len(calls), f"用量日志条数 ≥ 成功调用数（{len(calls)}）", f"{len(logs)}")
by_model = {}
for m, _ in calls:
    by_model[m] = by_model.get(m, 0) + 1
got = {}
for l in recent:
    got[l["requestModel"]] = got.get(l["requestModel"], 0) + 1
check(got == by_model, "每次成功调用各记一条日志（按模型）", f"want {by_model} got {got}")
bad = []
total = 0
for l in recent:
    m = l["requestModel"]
    pin, pout = USAGE[m]
    if (l["promptTokens"], l["completionTokens"]) != (pin, pout):
        bad.append(f"{m} tokens {l['promptTokens']}/{l['completionTokens']}")
    sin, sout = SALE[m]
    want = micro(sin, pin) + micro(sout, pout)
    if abs(l["charged"] - want) > 1:
        bad.append(f"{m} charged {l['charged']} want {want}")
    total += l["charged"]
check(not bad, "每条日志的 tokens 与扣费 = 售价 × 用量", "; ".join(bad))
check(all(not l.get("stream") is None for l in recent), "日志标注是否流式")
bal3 = ok_data(app("GET", "/gateway/usage/balance"), "balance")
check(bal2["balance"] - bal3["balance"] == total and bal3["reserved"] == 0, "余额减少 = 日志扣费合计，预留归零", f"{bal2} → {bal3} 扣费合计 {total}")
leak = [k for k in ("cost", "channelId", "upstreamModel") if any(k in l for l in recent)]
check(not leak, "用户用量日志不暴露内部成本与渠道", f"暴露了 {leak}")
tx = ok_data(app("GET", "/gateway/usage/transaction/page?pageNo=1&pageSize=50"), "transactions")["list"]
types = [t.get("type") for t in tx]
check("grant" in types or "recharge" in types, "流水里有充值入账", f"{types[:10]}")

st_a, st_b = mock_stats(19001), mock_stats(19002)
if st_a is not None:
    check(st_b["hits"].get("/v1/chat/completions", 0) >= 1, "故障线路确实被先尝试过（失败后才切换）", str(st_b["hits"]))
    last = st_a["last"].get("/v1/chat/completions", {})
    check(last.get("headers", {}).get("authorization") == "Bearer sk-mock-a", "转发给上游的是渠道 Key，不是用户 Key", str(last.get("headers")))
    check(st_a["last"].get("/v1/messages", {}).get("headers", {}).get("x-api-key") == "sk-mock-a", "Anthropic 渠道用 x-api-key 传渠道 Key")
    check(st_a["last"].get("/v1beta/models/gemini-2.5-flash:streamGenerateContent", {}).get("headers", {}).get("x-goog-api-key") == "sk-mock-a"
          or "gemini" in json.dumps(st_a["hits"]), "Gemini 渠道收到请求")

# ════════════════════════ 第二阶段：更多路径 ════════════════════════
print("[more] Responses、跨协议、停用 Key、限速、余额不足、并发")
import threading

s, _, b = http("POST", f"{API}/v1/responses", {"model": "gpt-4o-mini", "input": "hi"}, OAI)
out = json.dumps(b.get("output") if isinstance(b, dict) else b)
check(s == 200 and "mock-a" in out, "Responses 接口 /v1/responses", f"{s} {str(b)[:200]}")
time.sleep(2)
rl = ok_data(app("GET", "/gateway/usage/log/page?pageNo=1&pageSize=1"), "logs")["list"][0]
want = micro(SALE["gpt-4o-mini"][0], 1200) + micro(SALE["gpt-4o-mini"][1], 300)
check(rl["requestModel"] == "gpt-4o-mini" and (rl["promptTokens"], rl["completionTokens"]) == (1200, 300) and abs(rl["charged"] - want) <= 1,
      "Responses 调用按 input/output tokens 正确计费", f"{rl.get('promptTokens')}/{rl.get('completionTokens')} charged={rl.get('charged')} want={want}")
s, _, b = http("POST", f"{API}/v1/messages", {"model": "gemini-2.5-flash", "max_tokens": 128, "messages": [{"role": "user", "content": "hi"}]}, ANT)
check(s == 200 and "mock-a" in json.dumps(b.get("content") if isinstance(b, dict) else b), "跨协议：用 Anthropic 格式调 Gemini", f"{s} {str(b)[:200]}")

main_id = next(t["id"] for t in ok_data(app("GET", "/gateway/token/list"), "token list") if t.get("name") == "e2e-main")
app("PUT", f"/gateway/token/update-status?id={main_id}&status=0")
s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 50, "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s in (401, 403), "停用的 Key → 拒绝", f"{s} {str(b)[:120]}")
app("PUT", f"/gateway/token/update-status?id={main_id}&status=1")
s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 50, "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s == 200, "重新启用后恢复调用", f"{s} {str(b)[:120]}")

# 运营给用户建一个每分钟 2 次的 Key：第 3 次被拒
uid = next(u["id"] for u in admin("GET", f"/account/user/page?pageNo=1&pageSize=5&username={os.environ['MEMBER_USER']}")["list"] if u.get("username") == os.environ["MEMBER_USER"])
rkey = admin("POST", "/gateway/token/create", {"userId": uid, "name": "e2e-rpm", "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": "", "groupOverride": None, "rpmLimit": 2, "tpmLimit": None, "concurrencyLimit": None})
rkey = rkey.get("key") if isinstance(rkey, dict) else rkey
codes = [http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 50, "messages": [{"role": "user", "content": "hi"}]}, {"Authorization": f"Bearer {rkey}"})[0] for _ in range(3)]
check(codes[:2] == [200, 200] and codes[2] == 429, "运营设的每分钟 2 次限速：第 3 次 429", f"{codes}")

# 零余额用户：注册（已存在就登录）、建 Key、调用 → 402
poor_user, poor_pw = "e2epoor", "e2e-poor-pass-9"  # 用户名只允许字母数字下划线
r = http("POST", f"{ADMIN}/app/auth/register", {"mode": "USERNAME_PASSWORD", "username": poor_user, "password": poor_pw, "nickname": "e2e poor"})
ptok = ok_data(http("POST", f"{ADMIN}/app/auth/login-username", {"username": poor_user, "password": poor_pw}), "poor login")["accessToken"]
pbal = ok_data(app("GET", "/gateway/usage/balance", tok=ptok), "poor balance")
pk = ok_data(app("POST", "/gateway/token/create", {"name": "e2e-poor", "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": ""}, tok=ptok), "poor token")
pk = pk.get("key") if isinstance(pk, dict) else pk
s, _, b = http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 50, "messages": [{"role": "user", "content": "hi"}]}, {"Authorization": f"Bearer {pk}"})
check(pbal["available"] <= 0 and s == 402, "余额不足 → 402，不调上游", f"balance={pbal} http={s} {str(b)[:120]}")
pbal2 = ok_data(app("GET", "/gateway/usage/balance", tok=ptok), "poor balance")
check(pbal2 == pbal, "余额不足的请求不扣费、不留预留", f"{pbal} → {pbal2}")
for t in ok_data(app("GET", "/gateway/token/list", tok=ptok), "poor tokens") or []:
    app("DELETE", f"/gateway/token/delete/{t['id']}", tok=ptok)

# 并发 20 个请求：全部成功，扣费与余额对得上
time.sleep(2)
before = ok_data(app("GET", "/gateway/usage/balance"), "balance")
top_id = ok_data(app("GET", "/gateway/usage/log/page?pageNo=1&pageSize=1"), "logs")["list"][0]["id"]
res = []
def one():
    res.append(http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 300, "messages": [{"role": "user", "content": "hi"}]}, OAI)[0])
ths = [threading.Thread(target=one) for _ in range(20)]
[t.start() for t in ths]; [t.join() for t in ths]
check(res.count(200) == 20, "并发 20 个请求全部成功", f"{sorted(res)}")
time.sleep(4)
new_logs = [l for l in ok_data(app("GET", "/gateway/usage/log/page?pageNo=1&pageSize=50"), "logs")["list"] if l["id"] > top_id]
after = ok_data(app("GET", "/gateway/usage/balance"), "balance")
spent = sum(l["charged"] for l in new_logs)
each = micro(SALE["gpt-4o-mini"][0], 1200) + micro(SALE["gpt-4o-mini"][1], 300)
check(len(new_logs) == 20 and all(l["charged"] == each for l in new_logs), f"并发 20 条日志、每条扣 {each} μUSD", f"{len(new_logs)} {[l['charged'] for l in new_logs][:5]}")
check(before["balance"] - after["balance"] == spent and after["reserved"] == 0, "并发后余额减少 = 扣费合计，预留归零", f"{before} → {after} spent={spent}")

# 上游拒绝请求（4xx）：错误原样转给用户，不扣费、预留当场释放
b0 = ok_data(app("GET", "/gateway/usage/balance"), "balance")
codes = [http("POST", f"{API}/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 50, "stream": st_, "metadata": {"mock_status": "400"},
                                                       "messages": [{"role": "user", "content": "hi"}]}, OAI)[0] for st_ in (False, True)]
time.sleep(2)
b1 = ok_data(app("GET", "/gateway/usage/balance"), "balance")
check(codes == [400, 400], "上游返回 400：用户收到 400（非流式与流式）", f"{codes}")
check(b1 == b0 and b1["reserved"] == 0, "上游 4xx 不扣费、预留当场释放", f"{b0} → {b1}")

stuck = admin("GET", "/gateway/settlement/manual-review")
check(not stuck, "没有卡在人工复核的结算单", f"{len(stuck)}")

for t in ok_data(app("GET", "/gateway/token/list"), "token list") or []:
    if str(t.get("name", "")).startswith("e2e-"):
        app("DELETE", f"/gateway/token/delete/{t['id']}")
for t in admin("GET", f"/gateway/token/list-by-user/{uid}") or []:
    if str(t.get("name", "")).startswith("e2e-"):
        admin("DELETE", f"/gateway/token/delete/{t['id']}")

passed = sum(1 for ok, _, _ in RESULTS if ok)
print(f"═══ 结果：{passed} passed, {len(RESULTS) - passed} failed ═══")
sys.exit(0 if passed == len(RESULTS) else 1)

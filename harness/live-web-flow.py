#!/usr/bin/env python3
"""线上用户全流程（走网站，和真实用户一样）：网站注册 / 登录 → 管理员手动充值 → 网站建 Key →
三种协议各种接口调用 → 日志与余额逐笔对账 → Key 限制 → 清理。

与 live-e2e.py 互补：那份直接打后端 API，这份经过网站的 /api/auth/* 与 /api/backend 代理（CSRF、会话 Cookie、
浏览器设备号）。上游用服务器本机的模拟厂商（见 live-e2e.py 文件头），只调已上架的 5 个 e2e 模型，不花钱。

环境变量：ADMIN_USER / ADMIN_PASSWORD；WEB_URL（缺省 https://neton.cloud）、API_URL、ADMIN_URL。
每次新注册一个 e2eu… 用户（充值 $5），跑完删掉本次建的 Key；用户保留。
"""
import http.cookiejar, json, math, os, secrets, sys, time, urllib.error, urllib.request, uuid

WEB = os.environ.get("WEB_URL", "https://neton.cloud").rstrip("/")
API = os.environ.get("API_URL", "https://api.neton.cloud").rstrip("/")
ADMIN = os.environ.get("ADMIN_URL", "https://admin.neton.cloud").rstrip("/")
DEVICE_ID = str(uuid.uuid4())  # 浏览器生成并持久化的设备号（client-runtime device-id.ts）
RES = []
jar = http.cookiejar.CookieJar()
web_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
plain = urllib.request.build_opener()


def check(ok, name, detail=""):
    RES.append((bool(ok), name))
    print(f"  {'✅' if ok else '❌'} {name}" + ("" if ok else f"  [{detail}]"), flush=True)


def req(opener, method, url, body=None, headers=None, raw=False, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0 netonapi-e2e", **(headers or {})}
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with opener.open(r, timeout=timeout) as x:
            s, t = x.status, x.read().decode()
    except urllib.error.HTTPError as e:
        s, t = e.code, e.read().decode()
    if raw:
        return s, t
    try:
        return s, json.loads(t)
    except ValueError:
        return s, t


WEBH = {"Origin": WEB, "X-Neton-Csrf": "1"}
def web(method, path, body=None):
    return req(web_opener, method, WEB + path, body, WEBH)
def backend(method, path, body=None):
    return web(method, "/api/backend" + path, body)
def ok(r):
    s, b = r
    return s == 200 and isinstance(b, dict) and b.get("code") == 0
def sse(t):
    out = []
    for l in t.splitlines():
        if l.startswith("data:"):
            v = l[5:].strip()
            try: out.append(json.loads(v))
            except ValueError: out.append(v)
    return out


ATOK = req(plain, "POST", ADMIN + "/admin/system/auth/login", {"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASSWORD"]})[1]["data"]["accessToken"]
def admin(method, path, body=None):
    return req(plain, method, ADMIN + path, body, {"Authorization": "Bearer " + ATOK})

# ═══ 1. 网站页面 ═══
print("[1] 网站页面")
for p in ["/", "/models", "/pricing", "/register", "/login", "/docs"]:
    s, t = req(web_opener, "GET", WEB + p, raw=True)
    check(s in (200,), f"GET {p} → {s}", t[:80]) if p in ("/", "/register", "/login") else print(f"     (信息) GET {p} → {s}")

# ═══ 2. 注册、登出、登录 ═══
print("[2] 注册 / 登录")
uname, pw = "e2eu" + secrets.token_hex(4), "Pw-" + secrets.token_hex(8)
s, b = web("POST", "/api/auth/register", {"username": uname, "password": pw, "nickname": "E2E 测试"})
check(not ok((s, b)) and "DEVICE_ID" in json.dumps(b), f"不带设备号注册被拒（{s} {b.get('message') if isinstance(b, dict) else ''}）", str(b)[:200])
s, b = web("POST", "/api/auth/register", {"username": uname, "password": pw, "nickname": "E2E 测试", "deviceId": DEVICE_ID})
check(ok((s, b)), f"注册 {uname}", f"{s} {str(b)[:200]}")
s, b = web("POST", "/api/auth/register", {"username": uname, "password": pw, "deviceId": DEVICE_ID})
check(not ok((s, b)), f"重复注册被拒（{s} {b.get('message') if isinstance(b, dict) else ''}）", str(b)[:200])
s, b = req(web_opener, "POST", WEB + "/api/auth/login", {"username": uname, "password": pw, "deviceId": DEVICE_ID}, {"Origin": "https://evil.example"})
check(s == 403, f"跨站登录请求被 CSRF 拦截（{s}）", str(b)[:120])
s, b = web("POST", "/api/auth/logout", {})
check(s == 200, f"登出 → {s}", str(b)[:120])
s, b = backend("GET", "/app/member/user/get")
check(s == 401 or (isinstance(b, dict) and b.get("code") != 0), f"登出后访问用户信息被拒（{s}）", str(b)[:120])
s, b = web("POST", "/api/auth/login", {"username": uname, "password": pw + "x", "deviceId": DEVICE_ID})
check(not ok((s, b)), f"错误密码登录失败（{s} {b.get('message') if isinstance(b, dict) else ''}）", str(b)[:120])
s, b = web("POST", "/api/auth/login", {"username": uname, "password": pw, "deviceId": "not-a-uuid"})
check(not ok((s, b)) and "INVALID_DEVICE_ID" in json.dumps(b), f"设备号格式不对被拒（{s} {b.get('message') if isinstance(b, dict) else ''}）", str(b)[:200])
s, b = web("POST", "/api/auth/login", {"username": uname, "password": pw, "deviceId": DEVICE_ID})
check(ok((s, b)), "正确密码登录", f"{s} {str(b)[:200]}")
s, b = backend("GET", "/app/member/user/get")
check(ok((s, b)), f"登录后读取用户信息（{(b.get('data') or {}).get('username') if isinstance(b, dict) else ''}）", f"{s} {str(b)[:200]}")
UID = int((b.get("data") or {}).get("id") or 0)
s, b = backend("GET", "/app/gateway/usage/balance")
check(ok((s, b)) and b["data"]["balance"] == 0, f"新用户余额为 0（{b.get('data') if isinstance(b, dict) else b}）", str(b)[:200])

# ═══ 3. 零余额建 Key、调用应被拒 ═══
print("[3] 建 Key（零余额）")
s, b = backend("POST", "/app/gateway/token/create", {"name": "e2e-main", "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": ""})
check(ok((s, b)) and str(b["data"].get("key", "")).startswith("sk-"), "网站建 Key，返回明文 sk-…", f"{s} {str(b)[:200]}")
KEY = b["data"]["key"]; KID = b["data"].get("id")
s, b = backend("GET", "/app/gateway/token/list")
lst = (b.get("data") or {}) if isinstance(b, dict) else {}
lst = lst.get("list", lst) if isinstance(lst, dict) else lst
row = next((t for t in lst or [] if t.get("id") == KID or t.get("name") == "e2e-main"), None)
check(row is not None and KEY not in json.dumps(row), "Key 列表里只显示掩码，不再返回明文", str(row)[:200])
KID = KID or (row or {}).get("id")
OAI = {"Authorization": "Bearer " + KEY}
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 16, "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s in (402, 403, 429) or (s >= 400), f"零余额调用被拒（{s} {str(b)[:120]}）", str(b)[:200])

# ═══ 4. 管理员手动充值 ═══
print("[4] 管理员手动充值 $5")
s, b = admin("POST", "/admin/gateway/quota/grant", {"userId": UID, "amount": 5_000_000, "ref": f"manual:e2e-{UID}"})
check(ok((s, b)), "管理员手动充值", f"{s} {str(b)[:200]}")
s, b = admin("POST", "/admin/gateway/quota/grant", {"userId": UID, "amount": 5_000_000, "ref": f"manual:e2e-{UID}"})
s2, b2 = backend("GET", "/app/gateway/usage/balance")
BAL0 = b2["data"]["balance"]
check(BAL0 == 5_000_000, f"同 ref 重复充值不重复入账，余额 {BAL0/1e6:.2f} USD", str(b2)[:200])

# ═══ 5. 调用 ═══
print("[5] 调用")
s, b = req(plain, "GET", API + "/v1/models", headers=OAI)
ids = sorted(m["id"] for m in b.get("data", [])) if isinstance(b, dict) else []
check(s == 200 and {"gpt-4o-mini", "gpt-4.1", "claude-sonnet-4", "gemini-2.5-flash", "text-embedding-3-small"} <= set(ids), f"/v1/models 列出 {ids}", f"{s} {str(b)[:200]}")

calls = []  # (名称, 期望模型)
def chat(model, stream=False, label=None):
    body = {"model": model, "max_tokens": 32, "messages": [{"role": "user", "content": "Say hello"}]}
    if stream:
        body.update(stream=True, stream_options={"include_usage": True})
        s, t = req(plain, "POST", API + "/v1/chat/completions", body, OAI, raw=True)
        ev = sse(t); js = [e for e in ev if isinstance(e, dict)]
        text = "".join((c.get("delta") or {}).get("content") or "" for e in js for c in e.get("choices", []))
        usage = next((e["usage"] for e in js if e.get("usage")), None)
        good = s == 200 and text and usage and ev[-1] == "[DONE]"
        check(good, f"{label or model} OpenAI 流式：{len(js)} 帧、文本 {text[:30]!r}、usage {usage}", f"{s} {t[:200]}")
    else:
        s, b = req(plain, "POST", API + "/v1/chat/completions", body, OAI)
        text = (((b.get("choices") or [{}])[0].get("message") or {}).get("content")) if isinstance(b, dict) else None
        usage = b.get("usage") if isinstance(b, dict) else None
        check(s == 200 and text and usage, f"{label or model} OpenAI 非流式：{text[:30]!r} usage {usage}", f"{s} {str(b)[:200]}")
    calls.append((label or model, model, usage))

chat("gpt-4o-mini"); chat("gpt-4o-mini", stream=True); chat("gpt-4.1")
chat("claude-sonnet-4", label="claude-sonnet-4（OpenAI 格式调 Anthropic 上游）")
chat("gemini-2.5-flash", label="gemini-2.5-flash（OpenAI 格式调 Gemini 上游）")

# Responses
s, b = req(plain, "POST", API + "/v1/responses", {"model": "gpt-4o-mini", "input": "Say hi", "max_output_tokens": 32}, OAI)
txt = ""
if isinstance(b, dict):
    for o in b.get("output", []):
        for c in o.get("content", []) or []:
            txt += c.get("text", "")
check(s == 200 and (txt or b.get("output_text")) and b.get("usage"), f"/v1/responses：{(txt or b.get('output_text') or '')[:30]!r} usage {b.get('usage') if isinstance(b, dict) else None}", f"{s} {str(b)[:200]}")
calls.append(("responses", "gpt-4o-mini", b.get("usage") if isinstance(b, dict) else None))

# Anthropic
ANT = {"x-api-key": KEY, "anthropic-version": "2023-06-01"}
s, b = req(plain, "POST", API + "/v1/messages", {"model": "claude-sonnet-4", "max_tokens": 32, "messages": [{"role": "user", "content": "Say hi"}]}, ANT)
t = "".join(c.get("text", "") for c in b.get("content", [])) if isinstance(b, dict) else ""
check(s == 200 and t and b.get("usage"), f"/v1/messages（x-api-key）claude-sonnet-4：{t[:30]!r} usage {b.get('usage') if isinstance(b, dict) else None}", f"{s} {str(b)[:200]}")
calls.append(("messages", "claude-sonnet-4", b.get("usage") if isinstance(b, dict) else None))
s, t = req(plain, "POST", API + "/v1/messages", {"model": "claude-sonnet-4", "max_tokens": 32, "stream": True, "messages": [{"role": "user", "content": "Say hi"}]}, ANT, raw=True)
types = [l[6:].strip() for l in t.splitlines() if l.startswith("event:")]
check(s == 200 and "message_start" in types and types[-1] == "message_stop", f"/v1/messages 流式事件 {sorted(set(types))}", f"{s} {t[:200]}")
calls.append(("messages-stream", "claude-sonnet-4", None))
s, b = req(plain, "POST", API + "/v1/messages", {"model": "gpt-4o-mini", "max_tokens": 32, "messages": [{"role": "user", "content": "Say hi"}]}, {"Authorization": "Bearer " + KEY, "anthropic-version": "2023-06-01"})
t = "".join(c.get("text", "") for c in b.get("content", [])) if isinstance(b, dict) else ""
check(s == 200 and t, f"/v1/messages 跨协议调 gpt-4o-mini（Bearer）：{t[:30]!r}", f"{s} {str(b)[:200]}")
calls.append(("messages-cross", "gpt-4o-mini", None))

# Gemini 原生
s, b = req(plain, "POST", API + "/v1beta/models/gemini-2.5-flash:generateContent", {"contents": [{"role": "user", "parts": [{"text": "Say hi"}]}]}, {"x-goog-api-key": KEY})
t = "".join(p.get("text", "") for c in (b.get("candidates") or []) for p in (c.get("content") or {}).get("parts", [])) if isinstance(b, dict) else ""
check(s == 200 and t and b.get("usageMetadata"), f"Gemini generateContent（x-goog-api-key）：{t[:30]!r} usage {b.get('usageMetadata') if isinstance(b, dict) else None}", f"{s} {str(b)[:200]}")
calls.append(("gemini", "gemini-2.5-flash", None))
s, t = req(plain, "POST", API + "/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse", {"contents": [{"role": "user", "parts": [{"text": "Say hi"}]}]}, {"x-goog-api-key": KEY}, raw=True)
ev = [e for e in sse(t) if isinstance(e, dict)]
check(s == 200 and ev, f"Gemini streamGenerateContent（x-goog-api-key）：{len(ev)} 帧", f"{s} {t[:200]}")
calls.append(("gemini-stream", "gemini-2.5-flash", None))
s, b = req(plain, "POST", API + "/v1beta/models/gpt-4o-mini:generateContent", {"contents": [{"role": "user", "parts": [{"text": "Say hi"}]}]}, {"x-goog-api-key": KEY})
check(s == 200 and isinstance(b, dict) and b.get("candidates"), f"Gemini 格式跨协议调 gpt-4o-mini → {s}", f"{s} {str(b)[:200]}")
calls.append(("gemini-cross", "gpt-4o-mini", None))

# Embeddings
s, b = req(plain, "POST", API + "/v1/embeddings", {"model": "text-embedding-3-small", "input": ["hello", "world"]}, OAI)
n = len(b.get("data", [])) if isinstance(b, dict) else 0
dim = len(b["data"][0]["embedding"]) if n else 0
check(s == 200 and n == 2 and dim > 0, f"/v1/embeddings：{n} 条、维度 {dim}、usage {b.get('usage') if isinstance(b, dict) else None}", f"{s} {str(b)[:200]}")
calls.append(("embeddings", "text-embedding-3-small", None))

# 错误路径
print("[6] 错误路径")
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "hi"}]}, {"Authorization": "Bearer sk-invalid000000"})
check(s == 401, f"无效 Key → {s}", str(b)[:150])
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "hi"}]})
check(s == 401, f"不带 Key → {s}", str(b)[:150])
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "no-such-model-x", "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s in (400, 404), f"不存在的模型 → {s} {str(b)[:100]}", str(b)[:150])
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini"}, OAI)
print(f"     (信息) 缺 messages → {s}（网关透传，由上游校验；模拟上游不校验）")
s, b = req(plain, "POST", API + "/v1beta/models/gemini-2.5-flash:generateContent?key=" + KEY, {"contents": [{"role": "user", "parts": [{"text": "hi"}]}]})
check(s == 200, f"Gemini ?key= 查询参数传 Key → {s}", str(b)[:120])
s, t = req(plain, "POST", API + f"/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse&key={KEY}", {"contents": [{"role": "user", "parts": [{"text": "hi"}]}]}, raw=True)
check(s == 200 and any(isinstance(e, dict) for e in sse(t)), f"Gemini 流式 ?alt=sse&key= → {s}", t[:120])
s, oe = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "messages": []}, {"Authorization": "Bearer sk-invalid000000"})
s2, ae = req(plain, "POST", API + "/v1/messages", {"model": "claude-sonnet-4", "messages": []})
s3, ge = req(plain, "POST", API + "/v1beta/models/gemini-2.5-flash:generateContent?key=sk-invalid0000", {"contents": []})
good = (s, s2, s3) == (401, 401, 401) and isinstance(oe, dict) and (oe.get("error") or {}).get("code") == "invalid_api_key" \
    and isinstance(ae, dict) and ae.get("type") == "error" and (ae.get("error") or {}).get("type") == "authentication_error" \
    and isinstance(ge, dict) and (ge.get("error") or {}).get("status") == "UNAUTHENTICATED"
check(good, "认证失败按协议回官方错误结构（OpenAI invalid_api_key / Anthropic authentication_error / Gemini UNAUTHENTICATED）", f"{s} {oe} | {s2} {ae} | {s3} {ge}")
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4.1-mini", "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s in (403, 404), f"未上架模型 gpt-4.1-mini → {s} {str(b)[:100]}", str(b)[:150])

# ═══ 7. 日志与对账 ═══
print("[7] 日志与对账")
time.sleep(4)
s, b = backend("GET", "/app/gateway/usage/log/page?pageNo=1&pageSize=50")
logs = (b.get("data") or {}).get("list", []) if isinstance(b, dict) else []
okcalls = [c for c in calls]
check(len([l for l in logs if l.get("status") == "ok"]) == len(logs) == len(okcalls) + 3,
      f"使用日志 {len(logs)} 条，全部 status=ok（{len(okcalls)} 次调用 + 缺 messages 透传 + 两次 ?key= 调用）", json.dumps(logs[:1], ensure_ascii=False)[:300])
if logs:
    print("     日志字段：", sorted(logs[0].keys()))
cost = sum(int(l["charged"]) for l in logs)
s, b = backend("GET", "/app/gateway/usage/balance")
bal = b["data"]
print("     余额：", bal)
check(BAL0 - bal["balance"] == cost and cost > 0, f"余额减少 {(BAL0-bal['balance'])} μUSD = 日志扣费合计 {cost} μUSD", f"bal={bal} cost={cost}")
check(not bal.get("reserved"), f"预留额度已归零（{bal.get('reserved')}）", str(bal))
PRICES = {"gpt-4o-mini": (0.15, 0.6), "gpt-4.1": (2, 8), "claude-sonnet-4": (3, 15), "gemini-2.5-flash": (0.3, 2.5), "text-embedding-3-small": (0.02, 0)}
s, pb = backend("GET", "/app/gateway/pricebook/mine")
print("     我的价目表：", str(pb)[:300])
book = {r["model"]: r["price"] for g in pb["data"] for r in g["rows"]}
mism = []
for l in logs:
    m = l["requestModel"]; pr = book[m]; ti, to = int(l["promptTokens"]), int(l["completionTokens"])
    exp = math.ceil(ti * float(pr["input"]) - 1e-9) + math.ceil(to * float(pr["output"]) - 1e-9)
    if exp != int(l["charged"]):
        mism.append((m, ti, to, pr["input"], pr["output"], l["charged"], exp))
check(not mism, f"逐笔扣费 = tokens × 「我的价目表」单价（{len(logs)} 笔逐项向上取整）", str(mism[:3]))
s, b = backend("GET", "/app/gateway/usage/stats")
print("     统计：", str(b)[:300])
check(ok((s, b)), "用量统计接口可用", f"{s} {str(b)[:150]}")

# ═══ 8. Key 限制 ═══
print("[7b] 用户定价：管理员给他 gpt-4o-mini 打 7 折")
s, b = admin("PUT", "/admin/gateway/price-rule/save", {"subjectType": "USER", "subjectId": str(UID), "model": "gpt-4o-mini", "mode": "OFFICIAL_DISCOUNT", "discount": "0.7"})
check(ok((s, b)), f"设 7 折（毛利 {(b.get('data') or {}).get('status') if isinstance(b, dict) else ''}）", f"{s} {str(b)[:200]}")
s, b = admin("GET", "/admin/gateway/price-rule/users")
mine = next((u for u in (b.get("data") or []) if u.get("userId") == UID), None) if isinstance(b, dict) else None
check(mine is not None and mine.get("models") == 1, f"「用户定价」列表里有他：{mine}", str(b)[:200])
s, pb = backend("GET", "/app/gateway/pricebook/mine")
row = next((r for g in pb["data"] for r in g["rows"] if r["model"] == "gpt-4o-mini"), None)
check(row and row["source"] == "USER" and row.get("discountBp") == 7000, f"他的价目表：gpt-4o-mini {row and row['price']['input']}/{row and row['price']['output']}、来源 {row and row['source']}、{row and row.get('discountBp')}", str(row)[:200])
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 32, "messages": [{"role": "user", "content": "hi"}]}, OAI)
time.sleep(3)
lg = backend("GET", "/app/gateway/usage/log/page?pageNo=1&pageSize=1")[1]["data"]["list"][0]
exp = math.ceil(int(lg["promptTokens"]) * 0.15 * 0.7 - 1e-9) + math.ceil(int(lg["completionTokens"]) * 0.6 * 0.7 - 1e-9)
check(s == 200 and int(lg["charged"]) == exp, f"按 7 折扣费：tokens {lg['promptTokens']}+{lg['completionTokens']} → {lg['charged']} μUSD（期望 {exp}）", f"{s} {lg}")
s, b = admin("DELETE", f"/admin/gateway/price-rule/delete?subjectType=USER&subjectId={UID}&model=gpt-4o-mini")
s2, pb = backend("GET", "/app/gateway/pricebook/mine")
row = next((r for g in pb["data"] for r in g["rows"] if r["model"] == "gpt-4o-mini"), None)
check(s == 200 and row and row["source"] != "USER", f"恢复原价：来源回到 {row and row['source']}", f"{s} {row}")

print("[8] Key 限制")
s, b = backend("POST", "/app/gateway/token/create", {"name": "e2e-limited", "quotaBudget": 1, "expiresAt": None, "allowedModels": "gpt-4o-mini", "allowedIps": ""})
K2 = b["data"]["key"] if ok((s, b)) else None; K2ID = b["data"].get("id") if ok((s, b)) else None
check(K2, "建受限 Key（只许 gpt-4o-mini、额度 1 μUSD）", f"{s} {str(b)[:200]}")
if K2:
    H2 = {"Authorization": "Bearer " + K2}
    s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4.1", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}, H2)
    check(s in (403, 404), f"受限 Key 调不允许的模型 gpt-4.1 → {s} {str(b)[:100]}", str(b)[:150])
    s, b = req(plain, "GET", API + "/v1/models", headers=H2)
    ids2 = [m["id"] for m in b.get("data", [])] if isinstance(b, dict) else []
    check(ids2 == ["gpt-4o-mini"], f"受限 Key 的 /v1/models 只列 {ids2}", str(ids2))
    s1, _ = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}, H2)
    s2, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}, H2)
    check(s2 in (402, 403, 429) or (s1 >= 400), f"Key 额度用尽后被拒（第一次 {s1}，第二次 {s2} {str(b)[:100]}）", str(b)[:150])
if KID:
    s, b = backend("PUT", f"/app/gateway/token/update-status?id={KID}&status=0", {})
    check(ok((s, b)), "停用主 Key", f"{s} {str(b)[:200]}")
    time.sleep(2)
    s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}, OAI)
    check(s in (401, 403), f"停用后调用被拒 → {s}", str(b)[:150])

# ═══ 9. 清理 ═══
print("[9] 清理")
for kid in [KID, K2ID]:
    if kid:
        s, b = backend("DELETE", f"/app/gateway/token/delete/{kid}")
        check(ok((s, b)), f"删除 Key #{kid}", f"{s} {str(b)[:150]}")
s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": "gpt-4o-mini", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}, OAI)
check(s == 401, f"删除后旧 Key 调用 → {s}", str(b)[:150])

print(f"\n本次用户 {uname}（#{UID}）")
bad = [n for o, n in RES if not o]
print(f"═══ 结果：{len(RES)-len(bad)} passed, {len(bad)} failed ═══")
sys.exit(0 if not bad else 1)

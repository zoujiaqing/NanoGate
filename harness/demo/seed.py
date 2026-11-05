#!/usr/bin/env python3
"""给本地演示实例灌一份「像在真实运营」的数据，供截图与演示用。

全部走管理端与用户端 API（和运营、用户真实的操作路径一样），最后把调用记录分散到最近 7 天，让趋势图有起伏。
渠道名、用户名都是虚构的；上游是 demo-upstream.py（随机但像真实流量的用量）。

环境变量：BASE（缺省 http://127.0.0.1:8810）、UPSTREAM（缺省 http://127.0.0.1:9850/v1）、PSQL（改造调用时间用的 psql 命令前缀）。
"""
import json, os, random, subprocess, sys, time, urllib.error, urllib.request, uuid

BASE = os.environ.get("BASE", "http://127.0.0.1:8810").rstrip("/")
UPSTREAM = os.environ.get("UPSTREAM", "http://127.0.0.1:9850/v1")
PSQL = os.environ.get("PSQL", "")
random.seed(42)


def http(method, path, body=None, token=None, headers=None):
    h = {"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {}), **(headers or {})}
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=60) as x:
            t = x.read().decode()
            return x.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try:
            return e.code, json.loads(t)
        except ValueError:
            return e.code, t


def ok(res, what):
    s, b = res
    if s != 200 or (isinstance(b, dict) and b.get("code", 0) != 0):
        print(f"FATAL {what}: {s} {str(b)[:300]}"); sys.exit(2)
    return b.get("data") if isinstance(b, dict) else b


A = ok(http("POST", "/admin/system/auth/login", {"username": "admin", "password": "admin123"}), "admin login")["accessToken"]
adm = lambda m, p, b=None: ok(http(m, "/admin" + p, b, A), f"{m} {p}")

print("[站点] NetonAPI")
adm("POST", "/system/setting/update", {"key": "system.site.name", "value": "NetonAPI"})
adm("POST", "/system/setting/update", {"key": "system.site.tagline", "value": "一个 Key 调用所有主流大模型，按官方价计费，每一笔都能对账"})

print("[模型] 官方价")
# (模型, 输入, 输出, 缓存读, 展示名)
MODELS = [
    ("gpt-5", "1.25", "10", "0.125"), ("gpt-5-mini", "0.25", "2", "0.025"), ("gpt-4.1", "2", "8", "0.5"),
    ("gpt-4.1-mini", "0.4", "1.6", "0.1"), ("gpt-4o", "2.5", "10", "1.25"), ("gpt-4o-mini", "0.15", "0.6", "0.075"),
    ("o3", "2", "8", "0.5"), ("claude-opus-4-8", "5", "25", "0.5"), ("claude-sonnet-4-6", "3", "15", "0.3"),
    ("claude-haiku-4-5-20251001", "1", "5", "0.1"), ("gemini-2.5-pro", "1.25", "10", "0.31"), ("gemini-2.5-flash", "0.3", "2.5", "0.075"),
    ("deepseek-v4-pro", "1.32", "3.96", "0.13"), ("deepseek-v4-flash", "0.3", "1.2", "0.03"), ("qwen3.7-max", "2.5", "7.5", "0.25"),
    ("glm-5.1", "1.4", "4.4", "0.14"), ("kimi-k3", "3", "15", "0.3"), ("text-embedding-3-small", "0.02", "0", "0"),
]
existing = {p["model"]: p for p in adm("GET", "/gateway/price/list")}
for m, i, o, c in MODELS:
    body = {"model": m, "inputPrice": i, "outputPrice": o, "cacheReadPrice": c, "cacheWritePrice": "0",
            "defaultMaxOutputTokens": None if "embedding" in m else 8192, "listed": 1}
    if m in existing:
        adm("PUT", "/gateway/price/update", {**body, "id": existing[m]["id"]})
    else:
        adm("POST", "/gateway/price/create", body)
prices = {p["model"]: p for p in adm("GET", "/gateway/price/list")}
for m, *_ in MODELS:
    if prices[m]["listed"] != 1:
        adm("PUT", f"/gateway/price/listed?id={prices[m]['id']}&listed=1")

print("[分组] 企业客户")
groups = {g["code"] for g in adm("GET", "/gateway/group/list")}
if "enterprise" not in groups:
    adm("POST", "/gateway/group/create", {"code": "enterprise", "name": "企业客户", "ratio": "0.95", "selectable": 0,
                                         "description": "签约企业客户，全站价 95 折"})

print("[渠道] 官方直连 + 中转站（虚构名字，成本按拿货折扣）")
GPT = [m for m, *_ in MODELS if m.startswith(("gpt", "o3", "text-embedding"))]
CLAUDE = [m for m, *_ in MODELS if m.startswith("claude")]
GEMINI = [m for m, *_ in MODELS if m.startswith("gemini")]
CN = [m for m, *_ in MODELS if m.startswith(("deepseek", "qwen", "glm", "kimi"))]
CHANNELS = [
    ("OpenAI 官方", GPT, "0.82", 10, "chat,embeddings"),
    ("Anthropic 官方", CLAUDE, "0.8", 10, "chat"),
    ("Google Vertex", GEMINI, "0.78", 10, "chat"),
    ("国内模型直连", CN, "0.75", 10, "chat"),
    ("合作中转站 A", GPT + CLAUDE + GEMINI, "0.55", 5, "chat,embeddings"),
]
have = {c["name"]: c for c in adm("GET", "/gateway/channel/list")}
for name, models, disc, prio, caps in CHANNELS:
    if name in have:
        continue
    adm("POST", "/gateway/channel/create", {"name": name, "type": "openai_compatible", "baseUrl": UPSTREAM, "groups": "default,enterprise",
                                           "models": ",".join(models), "capabilities": caps, "priority": prio, "weight": 1,
                                           "costSource": "official", "costDiscount": disc, "keys": ["sk-demo-" + uuid.uuid4().hex[:12]]})
chan = {c["name"]: c["id"] for c in adm("GET", "/gateway/channel/list")}
for m, *_ in MODELS:
    routes = [chan[n] for n, ms, *_ in CHANNELS if m in ms]
    adm("PUT", "/gateway/channel/model-routes", {"model": m, "routes": [{"channelId": c, "upstreamModel": None} for c in routes]})

print("[兑换码] 一批活动码")
adm("POST", "/gateway/redemption/generate", {"quotaMicro": 10_000_000, "count": 20, "note": "新用户活动"})

print("[用户] 注册、充值、建 Key")
USERS = [  # (用户名, 昵称, 充值美元, 偏好模型, 调用次数)
    ("acme_ai", "Acme 智能", 800, ["claude-sonnet-4-6", "gpt-5", "claude-opus-4-8", "gemini-2.5-pro"], 260),
    ("zhangwei", "张伟", 120, ["gpt-4.1", "gpt-4o-mini", "deepseek-v4-pro"], 140),
    ("lumen_studio", "Lumen Studio", 300, ["claude-sonnet-4-6", "claude-haiku-4-5-20251001", "gemini-2.5-flash"], 180),
    ("chenjing", "陈静", 60, ["deepseek-v4-flash", "qwen3.7-max", "glm-5.1"], 90),
    ("kite_labs", "Kite Labs", 200, ["gpt-5-mini", "gpt-4.1-mini", "text-embedding-3-small"], 150),
    ("wangfang", "王芳", 40, ["gpt-4o-mini", "gemini-2.5-flash"], 70),
    ("orbit_dev", "Orbit Dev", 150, ["kimi-k3", "o3", "gpt-5"], 80),
    ("liuyang", "刘洋", 30, ["deepseek-v4-flash", "claude-haiku-4-5-20251001"], 50),
]
KEYS = {}
for uname, nick, usd, prefer, n in USERS:
    dev = {"deviceId": str(uuid.uuid4()), "platform": "web"}
    pw = "Demo-" + uname + "-2026"
    http("POST", "/app/auth/register", {"mode": "USERNAME_PASSWORD", "username": uname, "password": pw, "nickname": nick, "device": dev})
    login = ok(http("POST", "/app/auth/login-username", {"username": uname, "password": pw, "device": dev}), f"login {uname}")
    tok, uid = login["accessToken"], int(login["userId"])
    adm("POST", "/gateway/quota/grant", {"userId": uid, "amount": usd * 1_000_000, "ref": f"manual:demo-{uname}"})
    keys = []
    for kname in (["生产环境", "测试环境"] if usd >= 150 else ["默认"]):
        k = ok(http("POST", "/app/gateway/token/create", {"name": kname, "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": ""}, tok), "key")
        keys.append(k)
    KEYS[uname] = (uid, tok, keys, prefer, n)

print("[协议价] Acme 智能：Claude Sonnet 85 折、GPT-5 9 折；生产 Key 走企业客户分组")
uid, tok, keys, *_ = KEYS["acme_ai"]
adm("PUT", "/gateway/price-rule/save", {"subjectType": "USER", "subjectId": str(uid), "model": "claude-sonnet-4-6", "mode": "OFFICIAL_DISCOUNT", "discount": "0.85", "remark": "年度合同"})
adm("PUT", "/gateway/price-rule/save", {"subjectType": "USER", "subjectId": str(uid), "model": "gpt-5", "mode": "OFFICIAL_DISCOUNT", "discount": "0.9", "remark": "年度合同"})
adm("PUT", f"/gateway/token/update-group?id={keys[0]['id']}&groupCode=enterprise")
uid2, *_ = KEYS["lumen_studio"]
adm("PUT", "/gateway/price-rule/save", {"subjectType": "USER", "subjectId": str(uid2), "model": "claude-haiku-4-5-20251001", "mode": "OFFICIAL_DISCOUNT", "discount": "0.9", "remark": "季度框架协议"})

print("[调用] 各用户按偏好模型调用")
total = 0
for uname, (uid, tok, keys, prefer, n) in KEYS.items():
    for i in range(n):
        m = random.choice(prefer)
        key = random.choice(keys)["key"]
        if "embedding" in m:
            body, path = {"model": m, "input": "hello"}, "/v1/embeddings"
        else:
            body, path = {"model": m, "max_tokens": 2048, "stream": random.random() < 0.4, "messages": [{"role": "user", "content": "hi"}]}, "/v1/chat/completions"
            if body["stream"]:
                body["stream_options"] = {"include_usage": True}
        r = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
        try:
            with urllib.request.urlopen(r, timeout=60) as x:
                x.read()
            total += 1
        except urllib.error.HTTPError as e:
            e.read()
    print(f"  {uname}: {n} 次")
# 几次不存在的模型，让错误率不是 0
for _ in range(6):
    r = urllib.request.Request(BASE + "/v1/chat/completions", data=json.dumps({"model": "gpt-9", "messages": [{"role": "user", "content": "hi"}]}).encode(),
                               headers={"Content-Type": "application/json", "Authorization": "Bearer " + KEYS["zhangwei"][2][0]["key"]})
    try:
        urllib.request.urlopen(r, timeout=30).read()
    except urllib.error.HTTPError as e:
        e.read()
print(f"  成功 {total} 次")

if PSQL:
    print("[时间] 调用分散到最近 7 天（越近越多）")
    time.sleep(3)
    sql = """
WITH r AS (SELECT id, (power(random(), 1.6) * 6.8 * 86400000)::bigint AS back FROM gateway_usage_logs)
UPDATE gateway_usage_logs l SET created_at = l.created_at - r.back FROM r WHERE l.id = r.id;
WITH r AS (SELECT id, (power(random(), 1.6) * 6.8 * 86400000)::bigint AS back FROM gateway_settlements)
UPDATE gateway_settlements s SET created_at = s.created_at - r.back, updated_at = s.created_at - r.back FROM r WHERE s.id = r.id;
UPDATE gateway_quota_transactions t SET created_at = s.created_at
  FROM gateway_settlements s WHERE t.ref = 'settlement:' || s.settlement_id;
"""
    out = subprocess.run(PSQL.split() + ["-c", sql], capture_output=True, text=True)
    print("  ", (out.stdout + out.stderr).strip().replace("\n", " ")[:300])
print("done")

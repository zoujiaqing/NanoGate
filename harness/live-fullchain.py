#!/usr/bin/env python3
"""真实上游全链路实测：选一个已配置的真实模型，从「新用户注册」走到「逐笔对账」，并验证定价规则。

与 live-e2e.py（模拟上游）互补：这里打的是真实上游，花真实的钱（每次几美分以内），所以调用次数少、max_tokens 小。

流程：
  1. 管理员：上架模型、指定服务上游（MODEL_ROUTES 里的渠道）；
  2. 新注册一个用户，管理员手动充值 $1；
  3. 用户建 Key；/v1/models 必须列出这个模型；
  4. 调用：OpenAI 非流式、OpenAI 流式（include_usage）、Anthropic 格式（跨协议）；
     每笔核对：日志 tokens 与上游返回的 usage 一致、扣费 = Σ tokens × 单价（逐项向上取整）、余额减少 = 扣费合计、预留归零；
  5. 定价规则：低于成本的官方价折扣被拦截（预览 LOSS、保存 409）；给这个用户设固定价后按固定价扣、
     「我的价目表」显示用户约定；限定开放时没规则看不到也调不通，「仅开放」规则后可用；
  6. 恢复：删规则、开放范围改回、模型恢复原上架状态与服务上游。

环境变量：ADMIN_USER / ADMIN_PASSWORD；MODEL（缺省 gpt-4.1-mini）；CHANNELS（逗号分隔渠道 ID，缺省 26,27）；
ADMIN_URL / API_URL 同 live-e2e.py。
"""
import json, os, sys, time, urllib.error, urllib.request, secrets, math

ADMIN = os.environ.get("ADMIN_URL", "https://admin.neton.cloud")
API = os.environ.get("API_URL", "https://api.neton.cloud")
MODEL = os.environ.get("MODEL", "gpt-4.1-mini")
CHANNELS = [int(x) for x in os.environ.get("CHANNELS", "26,27").split(",") if x.strip()]
RESULTS = []


def check(ok, name, detail=""):
    RESULTS.append(bool(ok))
    print(f"  {'✅' if ok else '❌'} {name}" + ("" if ok else f"  [{detail}]"), flush=True)


def http(method, url, body=None, headers=None, stream=False, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            if stream:
                return r.status, [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")]
            try:
                return r.status, json.loads(raw)
            except ValueError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def data(res, what):
    s, b = res
    if s != 200 or not isinstance(b, dict) or b.get("code", 0) not in (0, None):
        print(f"FATAL {what}: {s} {str(b)[:300]}"); sys.exit(2)
    return b.get("data")


def admin(method, path, body=None):
    return data(http(method, f"{ADMIN}/admin{path}", body, {"Authorization": f"Bearer {ATOK}"}), f"admin {method} {path}")


def app(method, path, body=None):
    return http(method, f"{ADMIN}/app{path}", body, {"Authorization": f"Bearer {MTOK}"})


def micro_cost(tokens, price):
    """tokens × 价格（USD / 1M）→ μUSD，向上取整（与网关逐项向上取整一致）。"""
    return math.ceil(tokens * float(price) - 1e-9) if tokens else 0


def latest_log():
    time.sleep(2)
    return data(app("GET", "/gateway/usage/log/page?pageNo=1&pageSize=1"), "logs")["list"][0]


# ════════ 1. 管理员：上架、服务上游 ════════
print(f"[admin] 模型 {MODEL}，上游渠道 {CHANNELS}")
ATOK = data(http("POST", f"{ADMIN}/admin/system/auth/login", {"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASSWORD"]}), "admin login")["accessToken"]
price_row = next((p for p in admin("GET", "/gateway/price/list") if p["model"] == MODEL), None)
if not price_row:
    print(f"FATAL {MODEL} 没有价格行"); sys.exit(2)
orig_listed, orig_access = price_row["listed"], price_row.get("access", "ALL")
orig_routes = [r for r in admin("GET", f"/gateway/channel/model-routes?model={MODEL}") if r["serving"]]
admin("PUT", f"/gateway/price/listed?id={price_row['id']}&listed=1")
admin("PUT", f"/gateway/channel/model-routes", {"model": MODEL, "routes": [{"channelId": c, "upstreamModel": None} for c in CHANNELS]})
OFF_IN, OFF_OUT = price_row["inputPrice"], price_row["outputPrice"]
markup = admin("GET", "/gateway/price/check")["markup"]
PLAT_IN, PLAT_OUT = str(float(OFF_IN) * float(markup)), str(float(OFF_OUT) * float(markup))
check(True, f"上架 {MODEL}（官方价 ${OFF_IN} / ${OFF_OUT}，加价率 ×{markup}）并指定服务上游 {CHANNELS}")

try:
    # ════════ 2. 新用户、手动充值 ════════
    uname = "fc" + secrets.token_hex(4)
    pw = "fc-" + secrets.token_hex(8)
    http("POST", f"{ADMIN}/app/auth/register", {"mode": "USERNAME_PASSWORD", "username": uname, "password": pw, "nickname": "fullchain"})
    login = data(http("POST", f"{ADMIN}/app/auth/login-username", {"username": uname, "password": pw}), "member login")
    MTOK, UID = login["accessToken"], int(login["userId"])
    admin("POST", "/gateway/quota/grant", {"userId": UID, "amount": 1_000_000, "ref": f"manual:fullchain-{UID}"})
    bal0 = data(app("GET", "/gateway/usage/balance"), "balance")
    check(bal0["balance"] == 1_000_000, f"新用户 {uname}(#{UID}) 管理员手动充值 $1 到账", str(bal0))

    # ════════ 3. 建 Key ════════
    created = data(app("POST", "/gateway/token/create", {"name": "fullchain", "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": ""}), "create token")
    KEY = created["key"]
    OAI = {"Authorization": f"Bearer {KEY}"}
    s, b = http("GET", f"{API}/v1/models", headers=OAI)
    ids = [m["id"] for m in (b.get("data") or [])] if isinstance(b, dict) else []
    check(s == 200 and MODEL in ids, f"用户建 Key，/v1/models 列出 {MODEL}", f"{s} {ids[:10]}")

    # ════════ 4. 三种调用，逐笔对账 ════════
    print("[call] 真实上游调用与逐笔对账")
    spent = 0

    def verify(name, usage_in, usage_out, pin, pout):
        global spent
        log = latest_log()
        want = micro_cost(log["promptTokens"], pin) + micro_cost(log["completionTokens"], pout)
        tokens_ok = usage_in is None or (log["promptTokens"], log["completionTokens"]) == (usage_in, usage_out)
        check(log["requestModel"] == MODEL and log["status"] == "success" and tokens_ok and abs(log["charged"] - want) <= 1,
              f"{name}：tokens {log['promptTokens']}+{log['completionTokens']}、扣费 {log['charged']} μUSD（期望 {want}）",
              f"log={ {k: log.get(k) for k in ('requestModel','status','promptTokens','completionTokens','charged')} } upstream usage={usage_in}/{usage_out}")
        spent += log["charged"]

    s, b = http("POST", f"{API}/v1/chat/completions", {"model": MODEL, "max_tokens": 16, "messages": [{"role": "user", "content": "Reply with one word: hello"}]}, OAI)
    u = b.get("usage", {}) if isinstance(b, dict) else {}
    check(s == 200 and (b.get("choices") or [{}])[0].get("message", {}).get("content"), "OpenAI 非流式：真实上游返回内容", f"{s} {str(b)[:200]}")
    verify("非流式", u.get("prompt_tokens"), u.get("completion_tokens"), PLAT_IN, PLAT_OUT)

    s, ev = http("POST", f"{API}/v1/chat/completions", {"model": MODEL, "max_tokens": 16, "stream": True, "stream_options": {"include_usage": True}, "messages": [{"role": "user", "content": "Count: 1 2 3"}]}, OAI, stream=True)
    chunks = [json.loads(e) for e in ev if e and e != "[DONE]"]
    su = next((c["usage"] for c in reversed(chunks) if c.get("usage")), {})
    text = "".join(((c.get("choices") or [{}])[0].get("delta") or {}).get("content") or "" for c in chunks)
    check(s == 200 and ev and ev[-1] == "[DONE]" and text, "OpenAI 流式：内容完整、以 [DONE] 结束、最后一块带用量", f"{s} {text[:60]!r} usage={su}")
    verify("流式", su.get("prompt_tokens"), su.get("completion_tokens"), PLAT_IN, PLAT_OUT)

    ANT = {"x-api-key": KEY, "anthropic-version": "2023-06-01"}
    s, b = http("POST", f"{API}/v1/messages", {"model": MODEL, "max_tokens": 16, "messages": [{"role": "user", "content": "Say hi"}]}, ANT)
    au = b.get("usage", {}) if isinstance(b, dict) else {}
    check(s == 200 and b.get("type") == "message" and b.get("content"), "Anthropic 格式调 OpenAI 系上游（跨协议）", f"{s} {str(b)[:200]}")
    verify("跨协议", au.get("input_tokens"), au.get("output_tokens"), PLAT_IN, PLAT_OUT)

    bal1 = data(app("GET", "/gateway/usage/balance"), "balance")
    check(bal0["balance"] - bal1["balance"] == spent and bal1["reserved"] == 0, f"余额减少 = 扣费合计 {spent} μUSD，预留归零", f"{bal0} → {bal1}")

    # ════════ 5. 定价规则 ════════
    print("[rule] 定价规则")
    rule = {"subjectType": "USER", "subjectId": str(UID), "model": MODEL}
    s, b = http("POST", f"{ADMIN}/admin/gateway/price-rule/preview", {**rule, "mode": "OFFICIAL_DISCOUNT", "discount": "0.5"}, {"Authorization": f"Bearer {ATOK}"})
    st = (b.get("data") or {}).get("status") if isinstance(b, dict) else None
    s2, b2 = http("PUT", f"{ADMIN}/admin/gateway/price-rule/save", {**rule, "mode": "OFFICIAL_DISCOUNT", "discount": "0.5"}, {"Authorization": f"Bearer {ATOK}"})
    check(st == "LOSS" and s2 == 409, f"官方价 5 折低于渠道成本：预览 {st}、保存 {s2}（亏本拦截）", f"{s}/{st} {s2} {str(b2)[:160]}")

    FIX_IN, FIX_OUT = f"{float(PLAT_IN) * 1.25:g}", f"{float(PLAT_OUT) * 1.25:g}"
    s, b = http("PUT", f"{ADMIN}/admin/gateway/price-rule/save", {**rule, "mode": "FIXED", "prices": json.dumps({"input": FIX_IN, "output": FIX_OUT}), "remark": "fullchain"}, {"Authorization": f"Bearer {ATOK}"})
    check(s == 200, f"给这个用户设固定价 ${FIX_IN} / ${FIX_OUT}", f"{s} {str(b)[:200]}")
    mine = data(app("GET", "/gateway/pricebook/mine"), "pricebook")
    row = next((r for g in mine for r in g["rows"] if r["model"] == MODEL), {})
    check(row.get("source") == "USER" and row.get("price", {}).get("output") == FIX_OUT, f"「我的价目表」显示用户约定价（{row.get('source')}，${row.get('price', {}).get('input')} / ${row.get('price', {}).get('output')}，相当于官方价 {row.get('discountBp')}/10000）", str(row)[:200])
    s, b = http("POST", f"{API}/v1/chat/completions", {"model": MODEL, "max_tokens": 16, "messages": [{"role": "user", "content": "Reply with one word: ok"}]}, OAI)
    u = b.get("usage", {}) if isinstance(b, dict) else {}
    check(s == 200, "按约定价调用成功", f"{s} {str(b)[:160]}")
    verify("约定价调用", u.get("prompt_tokens"), u.get("completion_tokens"), FIX_IN, FIX_OUT)

    http("DELETE", f"{ADMIN}/admin/gateway/price-rule/delete?subjectType=USER&subjectId={UID}&model={MODEL}", None, {"Authorization": f"Bearer {ATOK}"})
    admin("PUT", f"/gateway/price/access?id={price_row['id']}&access=RULES_ONLY")
    s, b = http("GET", f"{API}/v1/models", headers=OAI)
    hidden = MODEL not in [m["id"] for m in (b.get("data") or [])]
    s2, b2 = http("POST", f"{API}/v1/chat/completions", {"model": MODEL, "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}, OAI)
    check(hidden and s2 == 404, f"限定开放、无规则：/v1/models 不列、调用 {s2}", f"hidden={hidden} {s2} {str(b2)[:120]}")
    http("PUT", f"{ADMIN}/admin/gateway/price-rule/save", {**rule, "mode": "PLATFORM"}, {"Authorization": f"Bearer {ATOK}"})
    s, b = http("POST", f"{API}/v1/chat/completions", {"model": MODEL, "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}, OAI)
    check(s == 200, f"给这个用户「仅开放」规则后可以调用（{s}）", f"{s} {str(b)[:160]}")
    verify("仅开放后按平台价", None, None, PLAT_IN, PLAT_OUT)
finally:
    # ════════ 6. 恢复 ════════
    print("[restore] 恢复模型原状态")
    try:
        http("DELETE", f"{ADMIN}/admin/gateway/price-rule/delete?subjectType=USER&subjectId={UID}&model={MODEL}", None, {"Authorization": f"Bearer {ATOK}"})
    except NameError:
        pass
    admin("PUT", f"/gateway/price/access?id={price_row['id']}&access={orig_access}")
    admin("PUT", f"/gateway/channel/model-routes", {"model": MODEL, "routes": [{"channelId": r["channelId"], "upstreamModel": r.get("upstreamModel")} for r in orig_routes]})
    admin("PUT", f"/gateway/price/listed?id={price_row['id']}&listed={orig_listed}")
    print(f"  已恢复：listed={orig_listed} access={orig_access} 服务上游={[r['channelId'] for r in orig_routes]}")

print(f"═══ 结果：{sum(RESULTS)} passed, {len(RESULTS) - sum(RESULTS)} failed ═══")
sys.exit(0 if all(RESULTS) else 1)

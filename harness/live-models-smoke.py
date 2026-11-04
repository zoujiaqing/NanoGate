#!/usr/bin/env python3
"""线上已上架模型逐个冒烟：每个上架模型真实调用一次，核对调得通、扣费 = tokens × 价目表单价（逐项向上取整）。

上架模型、换渠道、改价之后跑一遍：「上架了却调不通」「调通了但扣费和展示对不上」都在这里暴露。
对话模型发一句话（推理模型多给些输出额度，否则可能只想不答），向量模型算一条 embedding。花费几美分。

环境变量：ADMIN_USER / ADMIN_PASSWORD；WEB_URL / API_URL / ADMIN_URL（缺省 neton.cloud 三个域名）。
跑完删掉本次建的 Key。设了 MEMBER_USER / MEMBER_PASSWORD 就用这个测试账号，否则新注册一个（e2es… 开头）。
"""
import http.cookiejar, json, math, os, secrets, sys, time, urllib.error, urllib.request, uuid

WEB = os.environ.get("WEB_URL", "https://neton.cloud").rstrip("/")
API = os.environ.get("API_URL", "https://api.neton.cloud").rstrip("/")
ADMIN = os.environ.get("ADMIN_URL", "https://admin.neton.cloud").rstrip("/")
REASONING = ("gpt-5", "o3", "o4", "deepseek-v4-pro", "kimi", "glm-5", "grok", "qwen3.7-max", "gemini-2.5-pro", "gemini-3")
jar = http.cookiejar.CookieJar()
web = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
plain = urllib.request.build_opener()
RES = []


def check(ok, name, detail=""):
    RES.append((bool(ok), name))
    print(f"  {'✅' if ok else '❌'} {name}" + ("" if ok else f"  [{detail}]"), flush=True)


def req(opener, method, url, body=None, headers=None, timeout=180):
    r = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method,
                               headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with opener.open(r, timeout=timeout) as x:
            s, t = x.status, x.read().decode()
    except urllib.error.HTTPError as e:
        s, t = e.code, e.read().decode()
    try:
        return s, json.loads(t)
    except ValueError:
        return s, t


def need(res, what):
    s, b = res
    if s != 200 or not isinstance(b, dict) or b.get("code", 0) != 0:
        print(f"FATAL {what}: {s} {str(b)[:300]}"); sys.exit(2)
    return b.get("data")


WEBH = {"Origin": WEB, "X-Neton-Csrf": "1"}
def backend(method, path, body=None):
    return req(web, method, WEB + "/api/backend" + path, body, WEBH)


def member_session(prefix):
    """有 MEMBER_USER / MEMBER_PASSWORD 就登录这个测试账号（不占注册限流：每 IP 每小时 10 次）；否则新注册一个。"""
    dev = str(uuid.uuid4())
    if os.environ.get("MEMBER_USER"):
        need(req(web, "POST", WEB + "/api/auth/login", {"username": os.environ["MEMBER_USER"], "password": os.environ["MEMBER_PASSWORD"], "deviceId": dev}, WEBH), "member login")
        return os.environ["MEMBER_USER"]
    name = prefix + secrets.token_hex(4)
    need(req(web, "POST", WEB + "/api/auth/register", {"username": name, "password": "Pw-" + secrets.token_hex(8), "deviceId": dev}, WEBH), "register")
    return name


ATOK = need(req(plain, "POST", ADMIN + "/admin/system/auth/login", {"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASSWORD"]}), "admin login")["accessToken"]
uname = member_session("e2es")
UID = int(need(backend("GET", "/app/member/user/get"), "me")["id"])
need(req(plain, "POST", ADMIN + "/admin/gateway/quota/grant", {"userId": UID, "amount": 5_000_000, "ref": f"manual:e2e-smoke-{UID}"},
         {"Authorization": "Bearer " + ATOK}), "grant")
BAL_START = need(backend("GET", "/app/gateway/usage/balance"), "balance")["balance"]
key = need(backend("POST", "/app/gateway/token/create", {"name": "e2e-smoke", "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": ""}), "key")
OAI = {"Authorization": "Bearer " + key["key"]}
book = {r["model"]: r for g in need(backend("GET", "/app/gateway/pricebook/mine"), "pricebook") for r in g["rows"]}
s, b = req(plain, "GET", API + "/v1/models", headers=OAI)
ids = sorted(m["id"] for m in b.get("data", [])) if isinstance(b, dict) else []
print(f"用户 {uname}（#{UID}），价目表 {len(book)} 个模型，/v1/models {len(ids)} 个")
check(sorted(book) == ids, "/v1/models 与控制台价目表是同一批模型", f"{sorted(set(book) ^ set(ids))}")

last = 0
spent = 0
try:
    for m in sorted(book):
        row = book[m]
        if "embedding" in m:
            s, b = req(plain, "POST", API + "/v1/embeddings", {"model": m, "input": "hello"}, OAI)
            good = s == 200 and isinstance(b, dict) and b.get("data") and b["data"][0].get("embedding")
        else:
            cap = 256 if m.startswith(REASONING) else 16
            s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": m, "max_tokens": cap, "messages": [{"role": "user", "content": "Reply with one word: ok"}]}, OAI)
            good = s == 200 and isinstance(b, dict) and b.get("choices")
        if not good:
            check(False, f"{m} 调用", f"{s} {str(b)[:240]}"); continue
        lg = None
        for _ in range(30):
            time.sleep(0.5)
            rows = need(backend("GET", "/app/gateway/usage/log/page?pageNo=1&pageSize=1"), "logs")["list"]
            if rows and rows[0]["id"] != last and rows[0]["requestModel"] == m:
                lg = rows[0]; break
        if lg is None:
            check(False, f"{m} 用量日志", "no log row"); continue
        last = lg["id"]
        pin, pout, pcr = float(row["price"]["input"]), float(row["price"]["output"]), float(row["price"]["cacheRead"])
        p, cr = int(lg["promptTokens"]), int(lg.get("cacheReadTokens") or 0)
        # 网关口径（PricingCalc）：缓存读比 prompt 还多 = 上游报的 prompt 不含缓存，分开计；缓存价为 0（价源没给）按输入价计
        fresh = p if cr > p else p - cr
        exp = math.ceil(fresh * pin - 1e-9) + math.ceil(cr * (pcr if pcr > 0 else pin) - 1e-9) + math.ceil(int(lg["completionTokens"]) * pout - 1e-9)
        spent += int(lg["charged"])
        tier = "（长上下文分档，按第一档）" if row.get("tiered") else ""
        check(int(lg["charged"]) == exp,
              f"{m}：{lg['latencyMs']}ms，tokens {lg['promptTokens']}+{lg['completionTokens']}{f'（缓存读 {cr}）' if cr else ''} × ${pin}/${pout} → 扣 {lg['charged']} μUSD（期望 {exp}）{tier}", str(lg))
    time.sleep(1)
    bal = need(backend("GET", "/app/gateway/usage/balance"), "balance")
    check(BAL_START - bal["balance"] == spent and not bal["reserved"], f"余额减少 {BAL_START - bal['balance']} μUSD = 逐笔扣费合计 {spent} μUSD，预留归零", str(bal))
finally:
    backend("DELETE", f"/app/gateway/token/delete/{key['id']}")

bad = [n for o, n in RES if not o]
print(f"═══ 结果：{len(RES) - len(bad)} passed, {len(bad)} failed ═══")
sys.exit(0 if not bad else 1)

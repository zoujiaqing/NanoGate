#!/usr/bin/env python3
"""线上定价全环节：全站价 → 分组价 → 协议价，每一层都核对「用户看到的价格」与「实际扣的钱」是一回事。

走网站（与控制台页面同一条路：/api/auth/*、/api/backend 代理），调用走 api 域名。每一层都核对：
  - 控制台「模型与价格」（/app/gateway/pricebook/mine）：价格、来源（PLATFORM 全站价 / GROUP 分组价 / USER 协议价）、折扣；
  - 公开模型列表（/app/gateway/model/list，未登录也能看）：始终是全站价，不泄漏分组价与协议价；
  - /v1/models 列出这些模型；
  - 实际调用的扣费 = Σ tokens × 控制台上的单价（逐项向上取整）；最后余额减少 = 日志扣费合计。

层次：
  A 全站价：Key 不绑分组（default），价格 = 售价（官方价 × 全站加价率）。
  B 分组价：运营建一个倍率 0.8 的分组、给它设 gpt-4.1「官方价 75 折」，把 Key 指定到这个分组。
     gpt-4o-mini = 全站价 × 0.8（来源 全站价 × 分组倍率），gpt-4.1 = 官方价 × 0.75（来源 分组价，不再乘倍率）。
  C 协议价：给这个用户设 gpt-4.1「官方价 6 折」→ 覆盖分组价；gpt-4o-mini 不受影响。
  D 取消协议价 → 回到分组价；Key 取消指定 → 回到全站价。
上游是真实渠道（CHANNELS，缺省 openlux、v-api），十来次 max_tokens=32 的小调用，花费不到 1 美分。跑完删掉临时分组、规则、Key，渠道分组清单恢复原样。

环境变量：ADMIN_USER / ADMIN_PASSWORD；WEB_URL / API_URL / ADMIN_URL（缺省 neton.cloud 三个域名）。
"""
import http.cookiejar, json, math, os, secrets, sys, time, urllib.error, urllib.request, uuid

WEB = os.environ.get("WEB_URL", "https://neton.cloud").rstrip("/")
API = os.environ.get("API_URL", "https://api.neton.cloud").rstrip("/")
ADMIN = os.environ.get("ADMIN_URL", "https://admin.neton.cloud").rstrip("/")
# 承载 gpt-4.1 / gpt-4o-mini 的渠道：临时分组要加到它们的分组清单上（跑完恢复）
CHANNELS = [c.strip() for c in os.environ.get("CHANNELS", "openlux,v-api").split(",") if c.strip()]
RES = []
jar = http.cookiejar.CookieJar()
web_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
plain = urllib.request.build_opener()


def check(ok, name, detail=""):
    RES.append((bool(ok), name))
    print(f"  {'✅' if ok else '❌'} {name}" + ("" if ok else f"  [{detail}]"), flush=True)


def req(opener, method, url, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with opener.open(r, timeout=120) as x:
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
    return req(web_opener, method, WEB + "/api/backend" + path, body, WEBH)


ATOK = need(req(plain, "POST", ADMIN + "/admin/system/auth/login", {"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASSWORD"]}), "admin login")["accessToken"]
def admin(method, path, body=None):
    return need(req(plain, method, ADMIN + path, body, {"Authorization": "Bearer " + ATOK}), f"admin {method} {path}")


UPDATE_FIELDS = ("id", "name", "type", "baseUrl", "groups", "models", "capabilities", "modelMapping", "paramOverride", "priority", "weight",
                 "proxyUrl", "apiVersion", "providerConfig", "costDiscount", "costSource", "upstreamPricingFormat", "upstreamPricingUrl",
                 "upstreamGroupRatio", "upstreamCreditRate", "lossPolicy", "reasoningSuffix", "remark")
def channel_body(ch, groups):
    """渠道更新只收 UpdateChannelRequest 的字段（未知字段会被 400），只改分组清单。"""
    return {**{k: ch[k] for k in UPDATE_FIELDS if k in ch}, "groups": groups}


def micro(v):
    """价格串（USD/1M）→ μUSD/1M 整数（6 位小数截断，与网关 parseMicro 一致）。"""
    s = str(v); i, _, f = s.partition(".")
    return int(i or 0) * 1_000_000 + int((f + "000000")[:6] or 0)


def charge_of(tokens_in, tokens_out, price):
    """Σ tokens × 单价（μUSD/1M）/ 1e6，逐项向上取整。"""
    return -(-tokens_in * micro(price["input"]) // 1_000_000) + -(-tokens_out * micro(price["output"]) // 1_000_000)


def pricebook():
    return {r["model"]: (g["groupCode"], r) for g in need(backend("GET", "/app/gateway/pricebook/mine"), "pricebook") for r in g["rows"]}


def call_and_check(model, price, label):
    s, b = req(plain, "POST", API + "/v1/chat/completions", {"model": model, "max_tokens": 32, "messages": [{"role": "user", "content": "hi"}]}, OAI)
    if s != 200:
        check(False, f"{label}：调用 {model}", f"{s} {str(b)[:200]}"); return 0
    lg = None
    for _ in range(20):
        time.sleep(0.5)
        rows = need(backend("GET", "/app/gateway/usage/log/page?pageNo=1&pageSize=1"), "logs")["list"]
        if rows and rows[0]["id"] != LAST[0]:
            lg = rows[0]; break
    if lg is None:
        check(False, f"{label}：{model} 用量日志", "no new log row"); return 0
    LAST[0] = lg["id"]
    exp = charge_of(int(lg["promptTokens"]), int(lg["completionTokens"]), price)
    check(int(lg["charged"]) == exp, f"{label}：调用 {model}，tokens {lg['promptTokens']}+{lg['completionTokens']} × ${price['input']}/${price['output']} → 扣 {lg['charged']} μUSD（期望 {exp}）", str(lg))
    return int(lg["charged"])


# ════════ 准备：注册、充值、建 Key ════════
print("[准备] 网站注册、管理员充值 $5、网站建 Key")
DEVICE = str(uuid.uuid4())
uname, pw = "e2ep" + secrets.token_hex(4), "Pw-" + secrets.token_hex(8)
need(req(web_opener, "POST", WEB + "/api/auth/register", {"username": uname, "password": pw, "deviceId": DEVICE}, WEBH), "register")
UID = int(need(backend("GET", "/app/member/user/get"), "me")["id"])
admin("POST", "/admin/gateway/quota/grant", {"userId": UID, "amount": 5_000_000, "ref": f"manual:e2e-pricing-{UID}"})
key = need(backend("POST", "/app/gateway/token/create", {"name": "e2e-pricing", "quotaBudget": None, "expiresAt": None, "allowedModels": "", "allowedIps": ""}), "create key")
KEY, KID = key["key"], key["id"]
OAI = {"Authorization": "Bearer " + KEY}
LAST = [0]
BAL0 = need(backend("GET", "/app/gateway/usage/balance"), "balance")["balance"]
print(f"  用户 {uname}（#{UID}），Key #{KID}")

catalog = {m["model"]: m for m in need(req(plain, "GET", WEB + "/api/backend/app/gateway/model/list"), "public models")}
markup = admin("GET", "/admin/gateway/price/check")["markup"]
GROUP = "e2e-pricing-" + secrets.token_hex(3)
channels = [c for c in admin("GET", "/admin/gateway/channel/list") if c["name"] in CHANNELS]
orig_groups = {c["id"]: c["groups"] for c in channels}
spent = 0

try:
    # ════════ A 全站价 ════════
    print(f"[A] 全站价（Key 不绑分组；全站加价率 ×{markup}）")
    pb = pricebook()
    for m in ("gpt-4o-mini", "gpt-4.1"):
        g, r = pb[m]
        site = {"input": catalog[m]["inputPrice"], "output": catalog[m]["outputPrice"]}
        check(g == "default" and r["source"] == "PLATFORM" and micro(r["price"]["input"]) == micro(site["input"]) and micro(r["price"]["output"]) == micro(site["output"]),
              f"控制台 {m}：${r['price']['input']}/${r['price']['output']}，来源 全站价，与公开价格页一致（${site['input']}/${site['output']}）", f"{g} {r}")
    s, b = req(plain, "GET", API + "/v1/models", headers=OAI)
    ids = {x["id"] for x in b.get("data", [])} if isinstance(b, dict) else set()
    check({"gpt-4o-mini", "gpt-4.1"} <= ids, f"/v1/models 列出 gpt-4o-mini、gpt-4.1（共 {len(ids)} 个）", str(ids))
    spent += call_and_check("gpt-4o-mini", pb["gpt-4o-mini"][1]["price"], "全站价")
    spent += call_and_check("gpt-4.1", pb["gpt-4.1"][1]["price"], "全站价")

    # ════════ B 分组价 ════════
    print(f"[B] 分组价：建分组 {GROUP}（倍率 0.8），gpt-4.1 分组价「官方价 75 折」，Key 指定到这个分组")
    admin("POST", "/admin/gateway/group/create", {"code": GROUP, "name": "E2E 定价分组", "ratio": "0.8", "selectable": 0})
    for c in channels:
        ch = admin("GET", f"/admin/gateway/channel/get/{c['id']}")
        admin("PUT", "/admin/gateway/channel/update", channel_body(ch, ch["groups"] + "," + GROUP))
    admin("PUT", "/admin/gateway/price-rule/save", {"subjectType": "GROUP", "subjectId": GROUP, "model": "gpt-4.1", "mode": "OFFICIAL_DISCOUNT", "discount": "0.75"})
    admin("PUT", f"/admin/gateway/token/update-group?id={KID}&groupCode={GROUP}")
    toks = need(backend("GET", "/app/gateway/token/list"), "tokens")
    mine = next(t for t in (toks["list"] if isinstance(toks, dict) else toks) if t["id"] == KID)
    check(mine.get("group") == GROUP, f"控制台 Key 列表显示分组 {mine.get('group')}", str(mine)[:200])
    pb = pricebook()
    g, mini = pb["gpt-4o-mini"]; _, g41 = pb["gpt-4.1"]
    site_mini = catalog["gpt-4o-mini"]
    exp_mini = (micro(site_mini["inputPrice"]) * 8000 // 10000, micro(site_mini["outputPrice"]) * 8000 // 10000)
    check(g == GROUP and mini["source"] == "PLATFORM" and (micro(mini["price"]["input"]), micro(mini["price"]["output"])) == exp_mini,
          f"控制台 gpt-4o-mini：${mini['price']['input']}/${mini['price']['output']} = 全站价 × 分组倍率 0.8", f"{g} {mini} 期望 {exp_mini}")
    off41 = catalog["gpt-4.1"]["official"]
    exp41 = (micro(off41["input"]) * 7500 // 10000, micro(off41["output"]) * 7500 // 10000)
    check(g41["source"] == "GROUP" and g41.get("discountBp") == 7500 and (micro(g41["price"]["input"]), micro(g41["price"]["output"])) == exp41,
          f"控制台 gpt-4.1：${g41['price']['input']}/${g41['price']['output']}，来源 分组价，官方价 75 折（不再乘分组倍率）", f"{g41} 期望 {exp41}")
    pub = {m["model"]: m for m in need(req(plain, "GET", WEB + "/api/backend/app/gateway/model/list"), "public models")}
    check(pub["gpt-4.1"]["inputPrice"] == catalog["gpt-4.1"]["inputPrice"], f"公开价格页仍是全站价（gpt-4.1 ${pub['gpt-4.1']['inputPrice']}），不泄漏分组价", str(pub["gpt-4.1"]))
    spent += call_and_check("gpt-4o-mini", mini["price"], "分组价")
    spent += call_and_check("gpt-4.1", g41["price"], "分组价")

    # ════════ C 协议价 ════════
    print("[C] 协议价：给这个用户设 gpt-4.1「官方价 6 折」")
    r = admin("PUT", "/admin/gateway/price-rule/save", {"subjectType": "USER", "subjectId": str(UID), "model": "gpt-4.1", "mode": "OFFICIAL_DISCOUNT", "discount": "0.6"})
    check(r["status"] in ("OK", "THIN", "UNSERVED"), f"管理台保存协议价（毛利 {r['status']}）", str(r))
    users = admin("GET", "/admin/gateway/price-rule/users")
    check(any(u["userId"] == UID for u in users), "「协议定价」列表里有这个用户", str(users)[:200])
    pb = pricebook()
    _, u41 = pb["gpt-4.1"]; _, mini2 = pb["gpt-4o-mini"]
    expu = (micro(off41["input"]) * 6000 // 10000, micro(off41["output"]) * 6000 // 10000)
    check(u41["source"] == "USER" and u41.get("discountBp") == 6000 and (micro(u41["price"]["input"]), micro(u41["price"]["output"])) == expu,
          f"控制台 gpt-4.1：${u41['price']['input']}/${u41['price']['output']}，来源 协议价，官方价 6 折（覆盖分组价）", f"{u41} 期望 {expu}")
    check(mini2["source"] == "PLATFORM" and mini2["price"] == mini["price"], "gpt-4o-mini 不受影响，仍是全站价 × 分组倍率", str(mini2))
    spent += call_and_check("gpt-4.1", u41["price"], "协议价")

    # ════════ D 逐层回退 ════════
    print("[D] 取消协议价 → 分组价；Key 取消指定 → 全站价")
    admin("DELETE", f"/admin/gateway/price-rule/delete?subjectType=USER&subjectId={UID}&model=gpt-4.1")
    _, back41 = pricebook()["gpt-4.1"]
    check(back41["source"] == "GROUP" and back41["price"] == g41["price"], f"取消协议价后回到分组价 ${back41['price']['input']}/${back41['price']['output']}", str(back41))
    spent += call_and_check("gpt-4.1", back41["price"], "回到分组价")
    admin("PUT", f"/admin/gateway/token/update-group?id={KID}")
    g, site41 = pricebook()["gpt-4.1"]
    check(g == "default" and site41["source"] == "PLATFORM" and site41["price"]["input"] == catalog["gpt-4.1"]["inputPrice"], f"Key 取消指定后回到全站价 ${site41['price']['input']}/${site41['price']['output']}", f"{g} {site41}")
    spent += call_and_check("gpt-4.1", site41["price"], "回到全站价")

    # ════════ 对账 ════════
    print("[对账]")
    time.sleep(1)
    bal = need(backend("GET", "/app/gateway/usage/balance"), "balance")
    check(BAL0 - bal["balance"] == spent and not bal["reserved"], f"余额减少 {BAL0 - bal['balance']} μUSD = 逐笔扣费合计 {spent} μUSD，预留归零", str(bal))
finally:
    print("[清理]")
    req(plain, "DELETE", ADMIN + f"/admin/gateway/price-rule/delete?subjectType=USER&subjectId={UID}&model=gpt-4.1", None, {"Authorization": "Bearer " + ATOK})
    req(plain, "DELETE", ADMIN + f"/admin/gateway/price-rule/delete?subjectType=GROUP&subjectId={GROUP}&model=gpt-4.1", None, {"Authorization": "Bearer " + ATOK})
    req(plain, "PUT", ADMIN + f"/admin/gateway/token/update-group?id={KID}", None, {"Authorization": "Bearer " + ATOK})
    backend("DELETE", f"/app/gateway/token/delete/{KID}")
    for c in channels:
        s, ch = req(plain, "GET", ADMIN + f"/admin/gateway/channel/get/{c['id']}", None, {"Authorization": "Bearer " + ATOK})
        if s == 200:
            req(plain, "PUT", ADMIN + "/admin/gateway/channel/update", channel_body(ch["data"], orig_groups[c["id"]]), {"Authorization": "Bearer " + ATOK})
    gid = next((g["id"] for g in admin("GET", "/admin/gateway/group/list") if g["code"] == GROUP), None)
    if gid:
        s, b = req(plain, "DELETE", ADMIN + f"/admin/gateway/group/delete/{gid}", None, {"Authorization": "Bearer " + ATOK})
        print(f"  删除临时分组 {GROUP} → {s}")
    after = {c["id"]: c["groups"] for c in admin("GET", "/admin/gateway/channel/list")}
    for c in channels:
        print(f"  渠道 {c['name']} 分组清单恢复为 {after.get(c['id'])!r}（原 {orig_groups[c['id']]!r}）")

bad = [n for o, n in RES if not o]
print(f"═══ 结果：{len(RES) - len(bad)} passed, {len(bad)} failed ═══")
sys.exit(0 if not bad else 1)

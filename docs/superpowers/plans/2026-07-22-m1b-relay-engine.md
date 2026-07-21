# M1b：中转引擎 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/v1/chat/completions` + `/v1/embeddings` 真实转发到 OpenAI 兼容上游：同协议透传改写、渠道路由与重试、SSE 直通、usage 计费、用量日志。

**Architecture:** 管线 = TokenGuard(已有) → 读原始 body → RequestRewriter（JsonObject 保真改写）→ RelayRouter（分层加权+重试排除）→ NetonHttpClient（非流式 request / 流式 stream）→ 响应直写（非流式 json / 流式 stream{writeChunk} 原样转发）→ UsageExtractor → PricingCalc（μUSD）→ QuotaLogic.consume + UsageLogTable.insert。
纯函数（定价/路由/改写/usage 提取）独立 TDD；RelayEngine 只做编排；E2E 用 python 假上游冒烟。

**已核实 API：** `ctx.request.text()`、`NetonHttpBody.Json`、`stream(): Flow<Bytes|Text|End>`（非 2xx 首字节前抛 `NetonHttpError.Http(statusCode, body)`——重试窗口天然成立）、`response.stream{}`/`json()`、`Sha256.hex`、`query{where{and}}.update{set}`。

## Global Constraints

- 全部代码在 gateway 模块仓；测试经 newgate 聚合跑：`cd newgate && ./gradlew :module-gateway:macosArm64Test`
- 决策 A：同协议**最小侵入改写**——JsonObject 解析，只动 `model`、合并 `param_override`、流式补 `stream_options.include_usage`；其余字段原样保留
- 错误纪律：上游 4xx 语义透传但**擦除身份信息**（不透传上游 headers；error body 原样给但替换 model 名不做 v1）；余额不足 402；无可用渠道 503
- 重试：仅首字节前（连接错/超时/429/5xx），同序列不重复渠道，上限 = min(3, 候选数)
- 计费：预检只查余额>0 与令牌预算；结算按实际 usage；上游没回 usage 时 charged=cost=0 并记 status=partial（v1 宽松，M3 收紧为估算）

---

### Task 1: PricingCalc 纯函数（μUSD 计费）

**Files:** `logic/PricingCalc.kt`、`src/commonTest/kotlin/logic/PricingCalcTest.kt`

decimal 字符串（USD/1M tokens）→ μUSD Long：`parseMicro("3.5") = 3_500_000`（μUSD/1M tokens）；
`tokenCost(tokens, priceMicroPer1M) = tokens * priceMicroPer1M / 1_000_000`（Long 运算，向上取整）。
`charge(usage, price, groupRatio) 与 cost(usage, price, costDiscount)`；ratio/discount 同为 decimal 字符串（万分位精度整数化：`parseRatio("0.8")=8000`，乘后 /10000）。
测试向量：gpt 类价（input 2.5/output 10.0，1000+500 tokens，ratio 1.0 → charged=2500+5000=7500μUSD）；折扣 0.6 成本；缓存字段；perRequestPrice 优先；四舍五入边界（1 token）。

### Task 2: RelayRouter 纯函数（候选/分层加权/重试排除）

**Files:** `logic/RelayRouter.kt`、`RelayRouterTest.kt`

`candidates(channels, model, group)`：status=1 ∩（models 含 model 或 mapping 键含 model）∩ groups 交集。
`pick(candidates, excludeIds, random)`：过滤 exclude → 取最高 priority 层 → 层内 weight 加权随机（Random 注入可测）。
测试：模型过滤、组交集、priority 分层优先、weight 分布（固定 seed 断言选中）、排除后落到下一层、全排除返回 null。

### Task 3: RequestRewriter 纯函数（保真改写）

**Files:** `logic/RequestRewriter.kt`、`RequestRewriterTest.kt`

输入原始 body 字符串 + Channel → 输出 `Rewritten(body: String, upstreamModel: String, stream: Boolean)`：
JsonObject 解析；model 按 mapping 换名；param_override（JsonObject）浅合并覆盖；stream=true 时若无 `stream_options` 注入 `{"include_usage":true}`；**未知字段原样保留**。
测试：未知字段保真（如 `reasoning_effort`）、映射命中/未命中、override 覆盖 temperature、include_usage 注入且不覆盖已有值、非流式不注入。

### Task 4: UsageExtractor 纯函数

**Files:** `logic/UsageExtractor.kt`、`UsageExtractorTest.kt`

`fromJson(body)`：非流式响应 `usage{prompt_tokens,completion_tokens,prompt_tokens_details.cached_tokens}` → Usage。
`SseUsageAccumulator`：喂入透传的文本块，增量扫描 `data:` 行，记住最后一个含 `"usage"` 的 chunk 解析结果（跨块拼接半行）。
测试：非流式提取、cached_tokens、流式尾包 usage、chunk 撕裂在 JSON 中间、无 usage 返回 null。

### Task 5: RelayEngine + RelayController + /v1/models 真实化

**Files:** `logic/RelayEngine.kt`、`controller/gateway/RelayController.kt`、改 `ModelsController`

RelayEngine.relay(ctx, path)：verify 已由 Guard 做（Identity 里有 tokenId/userId）→ 余额/预算预检 →
Rewriter → Router 循环（重试窗口=NetonHttpException.Http(429/5xx)/Network/Timeout；已开流不重试）→
流式：首块前记 TTFB，`ctx.response` 设上游 content-type 后 `stream { writeChunk(bytes) }` 直通，同时喂 SseUsageAccumulator →
非流式：`request()` 拿 body，`response.json(body, status)` →
finally：PricingCalc → QuotaLogic.consume → tokens quotaUsed 累加 → UsageLogTable.insert（ok/error/partial）。
渠道 client 缓存：`RelayEngine` 内 map<channelId, NetonHttpClient>（proxyUrl/超时变更需重启，v1 接受，记 SPEC）。
错误响应：OpenAI error 格式 `{"error":{"message","type","code"}}`，402 insufficient_quota / 503 no_available_channel / 上游 4xx 原样 body。

### Task 6: E2E 冒烟（python 假上游）

`/tmp/fake-openai.py`（stdlib，POST /v1/chat/completions：非流式回 usage JSON；stream=true 回 3 个 SSE chunk + usage 尾包 + [DONE]）。
流程：起假上游 :9999 → psql 注册渠道（type=openai_compatible base_url=http://127.0.0.1:9999 models=gpt-test）+ 定价 + grant 额度 → 起 newgate →
非流式 curl 断言：200、body 透传、`gateway_usage_logs` 一行 charged/cost 正确、`gateway_quota_transactions` consume 一行；
流式 curl -N 断言：SSE 逐块到达、[DONE] 透传、usage 入账；
429 假上游模式断言：换渠道重试/无渠道 503；余额耗尽断言 402。

### Task 7: 收口——SPEC 更新 + 全量测试 + commit

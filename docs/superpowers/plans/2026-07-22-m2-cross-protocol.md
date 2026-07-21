# M2：跨协议入站 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans。checkbox 跟踪。

**Goal:** Claude `/v1/messages` 与 Gemini 原生入站；同协议透传优先落地（即时价值：Claude Code → Anthropic 兼容上游），跨协议经 neton-ai IR 转换殿后。

**Architecture:** 引入 `Protocol`（inbound 协议）概念。RelayEngine 按 (inbound 协议 × 渠道 type) 分派：同协议走协议专属透传（认证头/usage 提取/参数注入各异），跨协议经 IR 双向转换（依赖 neton-ai IR 扩展 IR-4/IR-1）。

**分片：**
- **Slice 1（本计划落地，无 IR 依赖）**：Claude `/v1/messages` → Anthropic 兼容上游同协议透传。覆盖 DeepSeek `/anthropic`、GLM/Kimi/MiniMax 的 Anthropic 端点、真 Anthropic。
- **Slice 2（IR 依赖）**：Claude `/v1/messages` → OpenAI 兼容上游（IR 转换，M2 头号跨协议场景）。需先做 neton-ai IR-4（流事件块结构）+ IR-1（多模态）。
- **Slice 3**：Gemini 原生入站 `/v1beta/*`（透传 + 跨协议）。

## Global Constraints

- 沿用 M1b：gateway 组、裸响应、路由重试、μUSD 计费、用量日志
- 协议专属差异集中在 `ProtocolAdapter`，RelayEngine 不散落 if(type==)
- 测试经 newgate 聚合；E2E 用 python 假 Anthropic 上游

---

### Task 1: ProtocolAdapter 抽象 + Anthropic/OpenAI 两实现

`logic/protocol/ProtocolAdapter.kt`：
```
interface ProtocolAdapter {
  val id: String                                  // "openai" / "anthropic"
  fun upstreamHeaders(apiKey: String): Map<String,String>
  fun rewrite(rawBody: String, channel: Channel): Rewritten   // 复用/特化 RequestRewriter
  fun extractUsage(responseBody: String): Usage?
  fun sseUsageAccumulator(): SseUsageAccumulator?             // 流式旁路
  fun errorBody(code: String, message: String): String       // 协议原生 error 格式
}
```
- OpenAiAdapter：现有逻辑搬入（Bearer、include_usage 注入、OpenAI usage、OpenAI error）
- AnthropicAdapter：`x-api-key`+`anthropic-version: 2023-06-01`；**不注入** include_usage（Anthropic 流式 message_delta 原生带 usage）；usage 从 `usage.input_tokens/output_tokens` 提取；error `{"type":"error","error":{"type","message"}}`
- 测试：两 adapter 的 header/usage/error 各自向量；Anthropic rewrite 不加 stream_options

### Task 2: UsageExtractor 增 Anthropic 解析

- 非流式：`usage:{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}` → Usage
- 流式 `AnthropicSseUsageAccumulator`：`message_start` 带 input_tokens；`message_delta` 带 output_tokens（累积取最后）；抗 chunk 撕裂
- 测试：非流式向量、缓存字段、message_start+message_delta 组合、撕裂

### Task 3: RelayEngine 协议分派 + RelayController /v1/messages

- `relay(ctx, userId, tokenId, inboundProtocol, path)`；controller 新增 `@Post("/messages")` 传 `anthropic`
- 渠道候选按「渠道 type 与 inbound 协议兼容」再过滤：Slice 1 只放行 `inbound=anthropic ∧ channel.type=anthropic`（同协议）；不兼容且无 IR 时跳过该渠道（lastError 记 "cross-protocol not yet supported"）
- execute 用 `ProtocolAdapter.upstreamHeaders/extractUsage/sseUsageAccumulator`；path 由渠道 type 决定上游端点（anthropic→/v1/messages）
- 计费/日志不变（requestModel 仍从 body 取；Anthropic 也是顶层 model 字段）

### Task 4: E2E（python 假 Anthropic 上游）

- `/tmp/fake-anthropic.py`：`POST /v1/messages`，非流式回 `{"type":"message","usage":{"input_tokens":1000,"output_tokens":500}}`；stream=true 回 `message_start`(input)→`content_block_delta`×3→`message_delta`(output)→`message_stop`
- 注册 anthropic 渠道（type=anthropic base_url=假上游 models=claude-test）+ 定价 + 令牌
- 断言：`/v1/messages` 非流式 200 透传 + 计费 7500/4500；流式逐块 + message_delta usage 入账；OpenAI SDK 打 `/v1/chat/completions` 到 anthropic 渠道时（无 openai 渠道）→ 503 cross-protocol（Slice 2 前的正确降级）

### Task 5: 收口 + SPEC + 提交

---

## Slice 2/3 前置（记录，不在本计划落地）

- neton-ai IR 扩展工单 IR-4（流事件块结构：BlockStarted/Stopped/UsageDelta）、IR-1（多模态内容块）——见 `docs/superpowers/specs/2026-07-m0-neton-ai-ir-audit.md`
- 跨协议 codec：`AnthropicMessages ↔ IR ↔ OpenAiChatCompletions` 双向，含 SSE 事件序列互转

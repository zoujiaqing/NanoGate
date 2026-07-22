# M2 Slice 3：Gemini 接入 + OpenAI 枢纽重构 — 实施计划

> REQUIRED SUB-SKILL: superpowers:executing-plans

**Goal:** 接入 Gemini 原生入站，形成 Gemini/GPT/Claude 三向 3×3 完整矩阵。

**架构决策（枢纽模型）：** 以 **OpenAI ChatCompletions 为内部枢纽格式**。跨协议 = inbound→hub→upstream 组合。
- 同协议：passthrough（不经 hub，保真，决策 A 不变）
- 跨协议：`inboundToHub(req)` → `hubToUpstream(req)`；响应 `upstreamToHub(resp)` → `hubToInbound(resp)`；
  当一端是 OpenAI 时该段为恒等。
- **收益**：3 协议只需写 2×3=6 组 X↔OpenAI 转换；Gemini↔Anthropic 免费组合（Gemini→OpenAI→Anthropic）。
  现有 OpenAI↔Anthropic 4 格行为**逐格等价**（identity 段替换直连 codec，结果相同）。

**已有可复用（Anthropic 全 6 向已存在）：** AnthropicToOpenAiRequest/Response/Stream + OpenAiToAnthropicRequest/Response/Stream。

## Global Constraints

- 测试经 newgate 聚合；纯函数 TDD
- Gemini 模型在 URL 路径 `/v1beta/models/{model}:{action}`——controller split 冒号，注入 model + stream(action==streamGenerateContent) 进 body 交引擎
- Gemini 认证 `x-goog-api-key`；上游端点 `/v1beta/models/{upstreamModel}:{action}`；usage 字段 `usageMetadata{promptTokenCount,candidatesTokenCount}`

---

### Task 1: Gemini↔OpenAI 六向 codec（纯函数 TDD）

`logic/protocol/codec/` 新增：
- `GeminiToOpenAiRequest`：contents(role user/model→user/assistant)→messages；systemInstruction→system 消息；
  parts text→content，inlineData→image_url，functionCall→tool_calls，functionResponse→tool 消息；
  generationConfig{maxOutputTokens→max_tokens,temperature,topP→top_p,stopSequences→stop}；
  tools.functionDeclarations→OpenAI tools。model 从注入的 "model" 字段取。
- `OpenAiToGeminiRequest`：反向（messages→contents，system→systemInstruction，max_tokens→generationConfig.maxOutputTokens，tool_calls→functionCall parts）
- `GeminiToOpenAiResponse`：candidates[0].content.parts→message.content/tool_calls；finishReason(STOP→stop,MAX_TOKENS→length,SAFETY→content_filter)；usageMetadata→usage
- `OpenAiToGeminiResponse`：反向（choices→candidates，usage→usageMetadata）
- `GeminiToOpenAiStream`：Gemini SSE(candidates parts)→OpenAI chunk 状态机
- `OpenAiToGeminiStream`：OpenAI chunk→Gemini SSE 状态机

每向 golden 向量测试。

### Task 2: buildTransform 重构为枢纽管线 + StreamTransformer 组合

- `Codecs` 注册表：per-protocol reqToHub/reqFromHub/respToHub/respFromHub/streamToHub/streamFromHub（openai=identity）
- buildTransform：同协议 passthrough；跨协议组合 inbound→hub→upstream
- `ChainedStreamTransformer`：feed 链式（t1.feed→t2.feed），finish 链式
- **回归铁律**：现有 OpenAI↔Anthropic 4 组 E2E 必须逐一复跑通过（行为等价验证）

### Task 3: GeminiAdapter + Gemini controller 路由

- `GeminiAdapter`：id=gemini，headers x-goog-api-key，upstreamPath 用 action+model，extractUsage usageMetadata，errorBody Gemini 格式，streamUsageAccumulator
- `GeminiRelayController`：`@Post("/v1beta/models/{modelAction}")`（gateway 组）；split 冒号→model/action；注入 model+stream 进 body；调 engine.relay(ctx, GeminiAdapter, path)
- adapterForChannel 加 "gemini"→GeminiAdapter

### Task 4: E2E — 三协议九宫格

假上游三个（openai/anthropic/gemini），验证 9 组合关键路径（重点新增格：Gemini 入站→三上游、三入站→Gemini 上游），非流式+流式+计费。

### Task 5: 收口 + SPEC §5 矩阵文档同步 + commit

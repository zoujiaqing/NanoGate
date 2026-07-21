# neton-ai IR 保真度审计（M0 → M2 前置）

日期：2026-07-22
目的：评估 neton-ai 中间表示（IR）对三协议（OpenAI ChatCompletions / Anthropic Messages / Gemini generateContent）跨协议转换的保真度缺口，产出 M2 开工前的扩展工单。
现状基线：neton-ai v0.1（AiContent 仅 Text；AiUsage 三字段；AiStreamEvent 8 事件）。

## 逐项核对

| # | 核对项 | IR 现状 | 涉及类型 | 结论/扩展建议 |
|---|--------|---------|----------|---------------|
| 1 | 多模态内容块（image url/base64、audio、document/PDF、video） | **缺失**——`AiContent` 仅 `Text`（注释已预留 v0.2 sealed 扩展位） | AiContent | 新增 `ImageUrl/ImageData(mediaType,data)/Audio/Document/Video` 变体；provider mapper 靠 sealed when 编译期提醒 |
| 2 | 思维链（Claude thinking/redacted_thinking、OpenAI reasoning_content/effort、Gemini thought） | **缺失** | AiContent、AiStreamEvent、GenerateTextRequest | 内容块加 `Thinking(text, signature?)/RedactedThinking(data)`；流事件加 `ThinkingDelta`；请求加 `reasoning(effort/budgetTokens)` 参数组 |
| 3 | 提示缓存（cache_control、cache read/write tokens、cached_tokens） | **缺失**——AiUsage 仅 input/output/total | AiUsage、AiMessage/AiContent | AiUsage 加 `cacheReadTokens/cacheWriteTokens/reasoningTokens`；内容块级 `cacheControl` 标注（Anthropic 语义，其他协议忽略） |
| 4 | 工具调用 | **基本齐**——并行 toolCalls、流式参数增量（ToolCallArgumentsDelta）、tool 角色回传、error 标记齐备；ToolChoice 需核对是否含 required/具体函数 | AiToolCall、AiStreamEvent、ToolChoice | 核对 ToolChoice 变体齐 `Auto/None/Required/Named(fn)`；缺则补 |
| 5 | 流式事件序列完备性 | **部分**——TextDelta/工具增量/Completed 齐；但无内容块结构（block index/type），无法无损重建 Anthropic content_block_start/stop 序列；无流中 usage 增量（message_delta.usage） | AiStreamEvent | 加 `BlockStarted(index,type)/BlockStopped(index)`（或 delta 事件携带 blockIndex）；加 `UsageDelta(usage)` |
| 6 | finish/stop 原因映射 | **够用**——Stop/Length/ToolCalls/ContentFilter/Other；refusal 归 ContentFilter 或 Other | AiFinishReason | 映射表写进 codec 测试 fixtures；可选加 `Refusal` |
| 7 | 采样参数 | **部分**——temperature/topP/maxTokens/stopSequences 有；缺 topK、frequency/presence_penalty、seed、logprobs、response_format | GenerateTextRequest | 补齐；跨协议不支持的参数按「静默丢弃 + debug 日志」策略并文档化（Claude maxTokens 必填由 codec 兜底默认值） |
| 8 | usage 字段全集 | **缺**——见 #3；另无 per-round 聚合语义变化 | AiUsage、UsageAggregator | 同 #3；UsageAggregator 校验缓存字段累加 |
| 9 | 结构化输出（json_schema / responseSchema） | **缺失** | GenerateTextRequest | 加 `responseFormat(JsonSchema)`；Claude 无原生 → codec 注入工具或提示词策略，标注非无损 |
| 10 | 未知字段透传通道 | **缺失**——metadata 仅 Map<String,String> 提示位，不承载任意 JSON | GenerateTextRequest、AiMessage | 加 `providerExtensions: JsonObject?`（请求级 + 消息级），跨协议转换时按目标协议白名单选择性透传。注意：**同协议场景不经 IR**（spec 决策 A 混合架构），此通道只需服务跨协议长尾 |

## M2 前必须完成的 IR 扩展工单

1. **IR-1 多模态内容块**（#1）——`AiContent` 加 5 变体 + OpenAI/Anthropic/Gemini 双向 mapper；破坏性：无（sealed 追加，非穷尽 when 编译警告驱动适配）
2. **IR-2 思维链**（#2）——内容块 + 流事件 + 请求参数；破坏性：`AiStreamEvent` sealed 追加，消费方 when 需处理 else
3. **IR-3 usage 缓存/推理字段**（#3/#8）——AiUsage 加 3 可空字段；破坏性：无
4. **IR-4 流事件块结构 + UsageDelta**（#5）——Anthropic 事件序列无损重建的关键；破坏性：同 IR-2
5. **IR-5 采样参数补齐 + responseFormat**（#7/#9）——破坏性：无（默认值追加）
6. **IR-6 providerExtensions 透传通道**（#10）——破坏性：无
7. **IR-7 ToolChoice 变体核对**（#4）——小

优先级：IR-4 > IR-1 > IR-3 > IR-2 > IR-5 > IR-6 > IR-7（Claude Messages 入站 → OpenAI 兼容上游是 M2 的头号场景，事件序列重建和多模态先行）。

## 附注

- 同协议请求走透传改写（spec 决策 A），上述缺口**只影响跨协议路径**；M1 不被阻塞。
- neton-ai 现有 UsageAggregator / StreamingToolLoop / DefaultModelRouter 与网关 Router 职责有重叠，M1 设计 module-gateway 时需划清：网关用自己的渠道路由，不复用 DefaultModelRouter（后者面向应用内调用）。

# M2 Slice 2：Claude ↔ OpenAI 跨协议直译 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans。

**Goal:** Claude `/v1/messages` 入站 → OpenAI 兼容上游（DeepSeek/Kimi/通义/本地 vLLM 等）。让 Claude Code 等 Anthropic 协议客户端用上纯 OpenAI 协议的便宜上游——M2 头号跨协议场景。

**Architecture（spec 决策 A）：** 跨协议编解码器在 **module-gateway 产品侧**（`logic/protocol/codec/`），JSON→JSON 直译**不经 IR**（保真优先，迭代快）。三个纯函数方向：请求 A→O、非流式响应 O→A、流式 SSE O→A。RelayEngine 在 inbound=anthropic ∧ channel=openai 时启用 codec。

**范围：** v1 覆盖 text + tool_use/tool_result（coding agent 刚需）；多模态 image 块转 OpenAI image_url；不覆盖的块（thinking 等）降级为文本或丢弃并 warn。

## Global Constraints

- 纯函数 TDD，golden fixtures 从真实 Anthropic/OpenAI 报文采集脱敏
- 计费仍以上游（OpenAI）usage 为准；对客户端回 Anthropic 格式 usage（input=prompt、output=completion）
- codec 失败（无法转换的结构）→ 400 invalid_request（Anthropic error 格式），不静默
- 测试经 newgate 聚合

---

### Task 1: 请求直译 AnthropicToOpenAiRequest（纯函数）

`logic/protocol/codec/AnthropicToOpenAiRequest.kt`：Anthropic Messages JSON → OpenAI ChatCompletions JSON。

映射规则：
- `model`（已由 RequestRewriter 换成上游名，codec 收到的是最终 body）→ 保留
- `system`（字符串或 block 数组）→ 置于 messages 首个 `{"role":"system","content":..}`
- `messages[]`：role user/assistant 保留；`content` 字符串→字符串；`content` block 数组：
  - `text` 块 → 文本（多块拼接或 OpenAI content 数组）
  - `image` 块（source.type=base64）→ `{"type":"image_url","image_url":{"url":"data:<media_type>;base64,<data>"}}`
  - `tool_use` 块（assistant）→ OpenAI `tool_calls:[{id,type:function,function:{name,arguments}}]`
  - `tool_result` 块（user）→ OpenAI `{"role":"tool","tool_call_id":..,"content":..}`
- `tools[]`（Anthropic input_schema）→ OpenAI `[{type:function,function:{name,description,parameters}}]`
- `tool_choice`：auto/any/tool → OpenAI auto/required/{type:function,function:{name}}
- `max_tokens`（必填）→ `max_tokens`；`stop_sequences`→`stop`；`temperature`/`top_p` 保留
- `stream` 保留
- 未知顶层字段：丢弃（跨协议不透传，与决策 A 同协议保真是两条路径）

测试向量：纯文本对话、system 字符串、system block、image base64 块、tool_use+tool_result 往返、tools schema、tool_choice 三态、max_tokens 必填、多 text 块拼接。

### Task 2: 非流式响应直译 OpenAiToAnthropicResponse（纯函数）

`logic/protocol/codec/OpenAiToAnthropicResponse.kt`：OpenAI ChatCompletions 响应 → Anthropic Messages 响应。

- `id`→`id`；固定 `type:"message"`, `role:"assistant"`
- `choices[0].message.content`（字符串）→ `content:[{type:text,text:..}]`
- `choices[0].message.tool_calls`→ `content:[{type:tool_use,id,name,input:<parsed arguments>}]`（与 text 块共存）
- `finish_reason` → `stop_reason`：stop→end_turn、length→max_tokens、tool_calls→tool_use、content_filter→其它
- `usage{prompt_tokens,completion_tokens}` → `usage{input_tokens,output_tokens}`
- `model`→`model`

测试：纯文本、tool_calls、finish_reason 映射表、usage 换名。

### Task 3: 流式 SSE 直译 OpenAiToAnthropicStream（状态机）

`logic/protocol/codec/OpenAiToAnthropicStream.kt`：喂入 OpenAI SSE chunk 文本，产出 Anthropic SSE 事件文本序列。

Anthropic 事件序列（必须完整合法，客户端 SDK 状态机严格）：
`message_start` → `content_block_start`(index0,text) → `content_block_delta`(text_delta)*N →
`content_block_stop` → `message_delta`(stop_reason+usage) → `message_stop`。
工具调用：text 块后追加 `content_block_start`(tool_use) + `input_json_delta`* + `content_block_stop`。

状态机职责：
- 首个 OpenAI chunk → 发 message_start（含 model、input_tokens 若已知否则 0）+ content_block_start
- `delta.content` → content_block_delta(text_delta)
- `delta.tool_calls` → 开新 tool_use 块（首次）+ input_json_delta（arguments 片段）
- 尾包 `usage` / `finish_reason` → content_block_stop + message_delta(stop_reason,output_tokens) + message_stop
- 抗 chunk 撕裂（复用 SSE 事件边界切分）

测试：纯文本流序列完整性、工具调用流、usage 尾包、finish_reason 映射、撕裂；断言产出的 Anthropic 事件序列可被重新解析且 block index 连续。

### Task 4: RelayEngine 接入 codec

- `adapterForChannel` 不变；新增跨协议判定：inbound=anthropic ∧ channel adapter=openai → 启用 CrossProtocolRelay
- execute 分支：请求体先经 AnthropicToOpenAiRequest（在 adapter.rewrite 之后，即先 model 映射再协议转换——或反序，需确认 rewrite 用 requestModel 而 codec 不动 model）；上游用 OpenAiAdapter 的 header/usage；响应经 O→A codec 后再 respondRaw / stream
- 计费：用 OpenAI usage（已有）；日志 requestModel=claude 名、upstreamModel=映射后 openai 名
- 移除 Slice 1 的「跨协议 503」在此组合下的降级

### Task 5: E2E（假 OpenAI 上游 + Anthropic 客户端形态）

- 复用 /tmp/fake-openai.py（返回 OpenAI 格式）
- 注册 openai 渠道 models 含 claude 请求名映射到 gpt（model_mapping `{"claude-x":"gpt-test"}`）
- curl 以 **Anthropic 请求格式**打 `/v1/messages`，断言：
  - 非流式响应是 **Anthropic 格式**（type:message、content 块、stop_reason、input/output_tokens）
  - 流式是 **Anthropic 事件序列**（message_start…message_stop）
  - 计费按 OpenAI usage 正确
  - tool_use 往返（请求带 tools，上游回 tool_calls，客户端收到 Anthropic tool_use 块）

### Task 6: 收口 + SPEC + Claude Code 真实客户端冒烟（可选，用真 key 或 anthropic SDK）

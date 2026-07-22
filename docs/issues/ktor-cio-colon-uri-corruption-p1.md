# P1 框架 bug：Ktor CIO (K/N) 含冒号路径段的 URI 每进程启动损坏

> 状态：待复现最小化并提交 neton 框架 issue
> 影响：Gemini 原生入站 `/v1beta/models/{model}:generateContent`（自定义方法冒号语法）
> 发现：2026-07-22，NewGate M2 Slice3

## 现象

请求 `POST /v1beta/models/m-openai:generateContent` 到 gateway 组。应用层读到的
`call.request.uri`（经 KtorHttpContext.path，KtorHttpAdapter.kt:810）**每进程启动时**
有一定概率损坏：把路径从头截掉固定 11 个字符。

- 正常进程：`ctx.request.path` = `/v1beta/models/m-openai:generateContent`（偏移 0）
- 损坏进程：`ctx.request.path` = `/v1beta/models/nerateContent`（`m-openai:ge` 11 字符被吃掉）

关键特征：
- **每进程启动确定**：一个进程若损坏，则该进程内所有此类请求一致损坏；重启进程可能正常
- 偏移固定为 11 字符（`m-openai:ge`），与 model 名/请求顺序/请求体无关
- OpenAI (`/v1/chat/completions`) / Anthropic (`/v1/messages`) 路径从未观测到损坏
- 损坏发生在**到达应用层之前**——`{modelAction}` 路径参数与 `call.request.uri` 同步损坏，
  应用层无法恢复原始 model

## 归因（待证）

疑似 Ktor CIO 原生请求行解析或 Kotlin/Native 字符串切片，在路径段含 `:`（RFC 3986 允许，
Google API 自定义方法语法）时的未初始化内存/指针偏移。per-process 确定性 + 固定偏移
指向进程初始化期的一次性内存布局差异。

## 复现

1. 注册 gateway 组含 `@Controller("/v1beta/models")` `@Post("/{modelAction}")` 的 controller
2. 反复冷启动进程，每次 `POST /v1beta/models/x:generateContent`
3. 约半数进程 `ctx.request.path` 缺失前 11 字符

## 影响与现状

- NewGate 的 Gemini↔OpenAI 六向 codec + 枢纽路由**已完成并单测通过**；
  正常进程下 Gemini 入站三格（→openai/anthropic/gemini 上游）端到端正确
- 仅**路由分发层**受此 bug 阻塞，产品侧无解——需框架层修复
- OpenAI↔Anthropic 4 格 + Gemini 上游 2 格（经 hub）稳定可用，不受影响

## 修复方向（框架层）

1. 定位 KtorHttpAdapter / Ktor CIO / K-N 中含 `:` 路径段的 uri 解析
2. 最小复现：裸 Neton app 单路由 `/{seg}` + curl 含冒号段，多进程冷启动统计
3. 修复后 NewGate Gemini 入站零改动即生效（codec/controller 已就位）

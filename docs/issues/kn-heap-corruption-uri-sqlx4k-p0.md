# P0/P1：Kotlin/Native 堆内存损坏，表现为 URI 字符串间歇损坏（疑似 sqlx4k FFI）

> 状态：已定性为 K/N 堆损坏（非逻辑 bug），根因疑为 sqlx4k Rust FFI 内存不安全
> 影响：Gemini 原生入站 `/v1beta/models/{model}:generateContent`（URL 含模型名，读到损坏值）
> 关联：与 sqlx4k NUMERIC panic（docs/issues/sqlx4k-numeric-decode-p0.md）可能同源
> 发现/深度调查：2026-07-22，NewGate M2 Slice3

## 现象

gateway 组请求 `POST /v1beta/models/m-openai:generateContent`，应用层读到的
`call.request.uri` / `call.request.local.uri` / `call.parameters["modelAction"]`
**间歇性损坏**：从最后一段前面截掉固定 11 字符，`m-openai:generateContent` → `nerateContent`，
完整路径变 `/v1beta/models/nerateContent`。三种 Ktor URI 访问器**同时**损坏，
说明损坏在 Ktor 路由匹配之前（原始请求行层）。

## 关键证据链（排除逻辑 bug，锁定内存损坏）

1. **非确定性到极致**：字节完全相同的测试场景，一轮 30/30 失败，另一轮 0/3 成功。
   相同输入不同输出 = 内存损坏铁证，非逻辑错误。
2. **只在重 DB 的完整 gateway 复现**；最小复现 app（DSL 路由 + 含冒号路径 + 前置请求 +
   读 body + 异步日志，逐一匹配）**从不复现**——唯一系统性差异是**数据库/sqlx4k**。
3. 损坏由**前序请求**诱发（单发 Gemini 请求稳定，前面打过若干 relay 请求后才损坏）——
   符合「前序请求的 native FFI 调用损坏堆，污染后续请求内存」。
4. 加任何观测（println / 错误回显读取 path）常使 bug 消失 = Heisenbug（时序/布局敏感）。

## 已排除的假设（4 个框架层修复均无效）

- `call.request.uri` → `call.request.local.uri`（早期看似有效实为运气，后续 30/30 复现）
- `ApplicationCallPipeline.Setup` 拦截器最早期固化 URI（Setup 阶段读到的已损坏）
- 从 `route.pattern` + `call.parameters` 重建路径（call.parameters 同样损坏）
- 网关组非根挂载（/gw）——仍复现

均无效证明损坏在 Neton 适配器/应用代码**之下**的 native 层。

## 根因（高置信）

Kotlin/Native 堆内存损坏，来自不安全的 Rust FFI。**sqlx4k 是头号嫌疑**：
- 已知 sqlx4k 1.12.0 内存不安全（NUMERIC 解码 `panic=abort`，见 P0 doc）
- gateway 每请求经 TokenGuard/额度/渠道/定价/日志多次 sqlx4k 调用；最小 repro 无 DB 不复现
- native 堆越界写/use-after-free 会随机破坏无关对象（此处是 Ktor 解析出的 URI String）

## 影响与现状

- NewGate 的 Gemini↔OpenAI 六向 codec + 枢纽路由**代码正确**，单测全过；
  堆未损坏时 Gemini 入站三格端到端正确。仅生产可靠性被堆损坏破坏。
- OpenAI↔Anthropic 4 格 + Gemini 上游 2 格（模型在 body，不读 URI）不受影响，稳定。

## 修复方向（架构/依赖层，需 owner 决策）

1. **首选**：修 sqlx4k 内存安全（与 NUMERIC P0 同源，一并解决）。手段：
   - 升级/替换 sqlx4k；或审计其 FFI 边界（CString 生命周期、缓冲所有权、panic 跨 FFI）
   - K/N 内存 sanitizer / `-Xg0` debug 模式下跑 gateway 压测，定位越界点
2. 备选：评估 hyper4k（Rust Hyper 引擎）替换 Ktor CIO——但 DB 仍是 sqlx4k，未必解决
3. 验证：sqlx4k 修复后，NewGate Gemini 入站零改动即稳定（codec/controller 已就位）

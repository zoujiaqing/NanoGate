# NewGate 设计文档

日期：2026-07-21
状态：待评审

## 1. 背景与目标

NewGate 是一个**通用开源 LLM API 中转站（网关）发行版**，对标 [new-api](https://github.com/QuantumNous/new-api)，基于 Neton 生态构建：

- 后端：`neton-application` 的 distribution fork（Kotlin/Native，单二进制部署）
- 前端：`neton-application-front` 的 distribution fork（React 19 + Next.js 16）

**目标：**

1. 提供 OpenAI / Anthropic / Gemini 三种原生入站协议面，任意协议入站可路由到任意类型上游（协议转换矩阵见 §5）
2. 完整的渠道管理：多渠道、多 Key、权重负载均衡、失败重试、自动禁用与健康恢复
3. 完整的商业化能力：用户注册、API 令牌、按 token 计费、充值、兑换码、分组倍率
4. 管理后台 + 普通用户控制台，双端同一前端 shell
5. 单二进制 + SQLite 零配置起步，MySQL/PostgreSQL 生产部署，别人可一键部署

**v1 非目标（明确不做）：**

- Midjourney / Suno 等异步任务型 API
- OpenAI Realtime（WebSocket 代理）
- AWS Bedrock / GCP Vertex 上游（SigV4 / GCP OAuth 签名，列入 v1.1）
- 多租户白标、模型市场
- module-platform（HMAC 开放平台）不进 v1：LLM 中转的对外认证就是 sk- 令牌本身，
  再叠加 AppID/HMAC 体系会造成两套计费与认证并存；platform 保留给未来企业级场景

## 2. 总体架构

### 2.1 仓库布局

| 仓库 | 内容 | 性质 |
|------|------|------|
| `neton` | 框架：服务端流式响应支持（M0 前置）、neton-ai IR 扩展 | 框架改动 |
| `NewGate` | 后端发行版：application 入口 + module-system + module-infra + **module-gateway**（新增，in-tree） | fork 自 neton-application |
| `neton-application-module-member` | C 端用户体系 | sibling include，复用 |
| `neton-application-module-payment` | 充值支付 | sibling include，复用 |
| `NewGate-front` | **管理台**前端发行版：shell + front-module-system + **front-module-gateway**（admin 页面） | fork 自 neton-application-front |
| `neton-application-client` | 生态新增：**C 端用户控制台通用底座**（React 19 + shadcn-ui，member 账号体系/JWT 对接 `app` 组，界面风格对标阿里云·腾讯云·AWS 控制台） | 新建 base 项目 |
| `NewGate-console` | 用户控制台 + 公开页发行版（余额/充值/令牌/用量/模型广场） | fork 自 neton-application-client |

### 2.2 路由组（四组）

| 组 | 挂载 | 认证 | 用途 |
|----|------|------|------|
| `admin` | `/admin` | JWT（管理员） | 管理后台 API |
| `app` | `/app` | JWT（member 用户） | 普通用户控制台：余额、充值、令牌、用量 |
| `gateway` | `/`（独占 `/v1/*`、`/v1beta/*`） | `Bearer sk-xxx` TokenGuard | LLM 协议面 |
| `platform` | `/platform` | HMAC | v1 保留不启用 |

`gateway` 组特性：

- 自定义 `TokenGuard`（查库校验 sk- 令牌：额度、过期、模型/IP 白名单），不走 JWT
- 响应不走 envelope 包装，按各协议原样输出（含 SSE 流与上游语义错误码）
- 独立限流（RPM/TPM）

### 2.3 请求管线（中转引擎）

```
Client
  → TokenGuard（令牌校验 + 额度预检 + RPM/TPM 限流）
  → RequestClassifier（识别入站协议 + 端点 + 请求模型名）
  → Router（用户分组 → 可用渠道候选集 → 按优先级分层、层内权重随机）
  → Codec（同协议：透传改写；跨协议：经 IR 双向转换，见 §4 决策 A）
  → UpstreamClient（neton-http client，Flow 流式拉取，渠道级超时/代理）
  → SseReEmitter（边收边转发给客户端；反向模型名映射）
  → UsageExtractor（从上游 usage 字段取实际用量）
  → Biller（按定价扣减额度，写台账）
  → UsageLogger（逐请求日志）
失败（首字节前）→ Router 取下一候选渠道重试
```

## 3. 核心决策记录（ADR）

### 决策 A：混合转发架构（透传改写 + IR 转换）

**同协议**（如 ChatCompletions 入站 → OpenAI 兼容上游）：**最小侵入 JSON 改写透传**——
只改 model 字段（模型映射）、按渠道配置增删参数，**未知字段原样保留**。
**跨协议**（如 Claude Messages 入站 → OpenAI 兼容上游）：经 neton-ai 的内部中间表示
（IR：AiMessage / AiStreamEvent）双向转换。

备选方案与取舍：

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| 全部经 IR 归一化（LiteLLM 式） | 架构统一 | 上游每周出新字段（reasoning_effort、cache_control 等），IR 永远追不上，同协议场景无谓丢失保真度 | 否 |
| 只做字节透传，不支持跨协议 | 最简单 | 丢掉 Claude Code → 便宜上游这类核心场景 | 否 |
| **混合（选定）** | 同协议零保真损失、跨协议按需转换 | 两条代码路径 | **是** |

跨协议编解码器放在 `module-gateway/protocol/` 包（产品侧，迭代快），稳定后可上提进 neton-ai。

### 决策 B：计费模型——干净的每百万 token 定价，不继承 one-api 倍率单位

new-api 的 `模型倍率 × 0.002/1K` 是 one-api 历史包袱。NewGate 采用：

- 每模型定价：输入 / 输出 / 缓存读 / 缓存写，单位 **USD / 1M tokens**（十进制存储）
- 支持按次计价模式（图像等固定单价模型）
- 用户分组倍率（default / vip / …，乘数）
- 额度余额以 **μUSD（BIGINT，1e-6 美元）** 记账，避免浮点误差
- 额度变动走台账（授予 / 消费 / 退还 / 兑换），可审计——优于 new-api 的单列 int

### 决策 C：用量以上游 usage 字段为准

流式请求向上游注入 `stream_options.include_usage`（OpenAI 兼容）/ 解析
`message_delta.usage`（Anthropic）/ `usageMetadata`（Gemini）。不移植 tiktoken。
额度**预检**用字符数估算，**结算**用上游实际 usage；极少数不回报 usage 的上游按估算计费并在渠道上标记。

### 决策 D：v1 上游渠道类型

`OpenAI 兼容`（覆盖 OpenAI、DeepSeek、Qwen、Moonshot、智谱、xAI、Groq、OpenRouter、
SiliconFlow、Ollama、vLLM 等绝大多数）、`Anthropic`、`Gemini`、`Azure OpenAI`
（ChatCompletions 语义 + 不同 URL/认证头）。Bedrock / Vertex 列入 v1.1。

### 决策 E：v1 服务端适配器只要求 Ktor CIO

服务端流式写出（M0）先在 KtorHttpAdapter 落地（Ktor 原生支持 `respondBytesWriter`）。
hyper4k 的流式 ABI（`respond_start / write / end`）作为后续增强，不阻塞 v1。

### 决策 F：令牌只存哈希

sk- 令牌格式沿用 `sk-` 前缀 + 48 位随机（客户端配置习惯与 new-api 一致），
库中存 SHA-256 哈希 + 前缀/后 4 位用于展示，创建时仅显示一次。优于 new-api 的明文存储。

## 4. 框架前置工作（M0）

1. **neton-http 服务端流式响应**：暴露流式响应类型（如 handler 返回
   `Flow<ByteArray>` / 写通道），KtorHttpAdapter 用 `respondBytesWriter` 实现，
   支持 SSE Content-Type、逐块 flush、客户端断连感知（取消上游拉取）
2. **neton-http client 校验**：`stream(): Flow<NetonHttpStreamChunk>` 在
   Kotlin/Native + TLS 下的长流稳定性压测；渠道级 HTTP 代理支持；
   multipart 请求体（音频转写上传，v1 允许整体缓冲 + 大小上限 32MB）
3. **neton-ai IR 扩展审计**：补齐 thinking/reasoning 块、cache_control、
   多模态 parts、工具调用流式增量、usage 缓存字段等，保证跨协议转换保真度
4. **gateway 路由组机制**：根路径挂载、绕过 envelope、可插拔 TokenGuard

## 5. 协议转换矩阵（v1）

入站端点 × 上游类型。「透传」= 最小侵入 JSON 改写；「IR」= 经中间表示转换；
「—」= 能力不存在，Router 过滤；Azure 与 OpenAI 兼容列语义相同（URL/认证不同）。

| 入站 ↓ \ 上游 → | OpenAI 兼容 / Azure | Anthropic | Gemini |
|---|---|---|---|
| `/v1/chat/completions` | 透传 | IR | IR |
| `/v1/messages`（Claude 原生） | IR | 透传 | IR |
| `/v1beta/...:generateContent`（Gemini 原生，含流式） | IR | IR | 透传 |
| `/v1/embeddings` | 透传 | — | IR（embedContent） |
| `/v1/responses` | 透传（支持者）/ 降级为 ChatCompletions | v1.1 | v1.1 |
| `/v1/images/generations` | 透传 | — | v1.1 |
| `/v1/audio/speech`、`/v1/audio/transcriptions` | 透传 | — | — |
| `/v1/rerank`（Jina/Cohere 风格，同 new-api） | 透传（rerank 类上游） | — | — |
| `/v1/models` | 本地生成：返回该令牌可用模型列表 | | |

流式：三种协议的 SSE 事件格式互转由 IR 层承担（Anthropic 的
message_start/content_block_delta 序列 ↔ OpenAI chunk ↔ Gemini streamGenerateContent）。
响应中的 model 字段做**反向模型映射**（用户请求什么名字就回什么名字）。

## 6. 领域模型（module-gateway 表）

命名沿用现有 `模块_复数` 约定：

| 表 | 关键字段 | 说明 |
|----|---------|------|
| `gateway_channels` | type、name、base_url、group、models(JSON)、model_mapping(JSON)、param_override(JSON)、priority、weight、status、timeout、proxy、settings(JSON) | 渠道 |
| `gateway_channel_keys` | channel_id、key(加密存储)、status、fail_count、last_error | 渠道多 Key，逐 Key 禁用（优于 new-api 换行分隔） |
| `gateway_tokens` | user_id、key_hash、key_display、name、quota_budget、quota_used、expires_at、allowed_models(JSON)、allowed_ips(JSON)、group_override、status | 用户 API 令牌 |
| `gateway_model_prices` | model、input_price、output_price、cache_read_price、cache_write_price、per_request_price、mode(token/次) | 定价（USD/1M） |
| `gateway_groups` | name、ratio、description | 用户分组倍率 |
| `gateway_quota_accounts` | user_id、balance(μUSD BIGINT) | 额度账户 |
| `gateway_quota_transactions` | user_id、type(grant/consume/refund/redeem)、amount、balance_after、ref | 额度台账 |
| `gateway_redemptions` | code、amount、status、used_by、used_at | 兑换码 |
| `gateway_usage_logs` | user_id、token_id、channel_id、request_model、upstream_model、prompt/completion/cache tokens、cost、ttfb_ms、latency_ms、stream、status、error_code | 逐请求日志 |

与现有模块的关系：

- **module-member**：普通用户身份（注册/登录/社交登录）；gateway 令牌与额度账户挂 member 用户
- **module-payment**：充值下单/支付回调；支付成功后按可配置汇率给 `gateway_quota_accounts` 授予额度（写台账，type=grant，ref=支付订单号）
- **module-system**：管理员、RBAC（权限码 `gateway:channel:*`、`gateway:token:*` 等）、审计日志
- **module-infra**：渠道健康巡检挂定时任务（Job）、动态配置存全局开关

## 7. 路由、容错与限流

- **候选集**：按（用户分组 ∩ 渠道分组）+ 请求模型（经渠道 model_mapping 展开）过滤
- **选择**：priority 分层，最高层内按 weight 加权随机；同一重试序列不重复渠道
- **重试**：仅在**首字节前**（连接失败 / 429 / 5xx / 超时）换渠道重试，最多 N 次（可配）；
  流已开始则不重试，向客户端发协议内错误事件后收尾
- **自动禁用**：Key 级连续失败计数 → 禁用该 Key；渠道全部 Key 禁用 → 渠道挂起；
  巡检 Job 定期探活（发送最小请求）恢复
- **超时**：分渠道配置 TTFB 超时、流式块间空闲超时、总超时
- **限流**：令牌级 RPM/TPM + 用户级 RPM。单机内存滑动窗口；多节点用 neton-redis（部署可选项）。
  TPM 采用「预扣估算、结算校正」
- **并发上限**：每用户并发流数上限（防止单用户占满连接）

## 8. 错误处理

- 内部统一 `RelayError(kind, status, message, upstreamDetail)`，按**入站协议**序列化
  （OpenAI error 对象 / Anthropic error / Gemini error），保持客户端 SDK 可解析
- 上游 4xx 语义透传（如上游 400 参数错误原样转达），但**擦除上游身份信息**
  （Key、组织 ID、内部 URL 一律不外泄），模型名做反向映射
- 额度不足：`402/403` + 协议内 error（quota 类 code）；限流：`429` + Retry-After
- 流中断：已产生的用量按上游最后一次 usage 或估算计费；日志记 status=partial

## 9. 前端（双发行版：管理台 + 用户控制台）

**决策（2026-07-21）**：管理台与用户控制台分为两个独立前端项目，不共用一个 shell：

- **NewGate-front**（fork neton-application-front）：仅管理台，B 端信息密度风格，登录走 `admin` 组（管理员 JWT）
- **neton-application-client**（新建生态底座）→ **NewGate-console**（fork）：C 端用户控制台 + 公开页，
  登录走 `app` 组（member JWT/HttpOnly Cookie），界面风格对标云厂商控制台（阿里云/腾讯云/AWS）与 new-api 用户端；
  架构沿用 neton-application-front 的 monorepo 模式（React 19 + Next.js + shadcn-ui + 模块契约），
  差异在账号体系（member 而非 system 用户）、导航（产品化侧边栏而非后端菜单驱动 RBAC）、公开路由（未登录可访问首页/模型广场/定价/文档）

**管理台 NewGate-front（admin 菜单）：**

- 仪表盘：请求量 / tokens / 消费 / 错误率 / TTFB p50·p95，按模型·渠道·用户维度
- 渠道管理：CRUD、多 Key、连通性测试、模型映射编辑、启停、健康状态板
- 定价管理：模型价格表（支持从预置 JSON 导入）、分组倍率
- 令牌管理（全局视角）、用户额度调整、兑换码生成
- 用量日志：筛选 / 导出

**用户控制台 NewGate-console（member 登录）：**

- 概览：余额、本月消费、用量曲线
- 我的令牌：创建（一次性展示）、限额、模型/IP 白名单、启停
- 充值：module-payment 收银台 + 兑换码兑换
- 用量明细
- 公开页（未登录）：首页、模型广场/价目表、关于

UI 组件一律走各自 front-kit（shadcn-ui）；i18n v1 中文优先，英文包 M5 补齐。

## 10. 部署形态

- 单二进制（~10MB scratch 镜像）+ SQLite：零配置试用
- MySQL / PostgreSQL：生产；SQL 迁移脚本按现有 `sql/{mysql,postgresql,sqlite}/` 约定
- Redis：可选，仅多节点限流/共享计数需要
- 发布物：GitHub Releases 预编译二进制（linuxX64/arm64、macOS）+ Docker 镜像 + docker-compose（后端 + 前端 + MySQL）
- 前端独立部署（Next.js standalone），`NETON_BACKEND_URL` 指向后端

## 11. 测试策略

- **协议编解码契约测试**：三协议请求/响应/SSE 事件的 golden fixtures（从真实 provider 采集脱敏），双向转换往返断言——这是回归风险最高的部位
- **流式集成测试**：进程内 fake upstream（可注入延迟、中断、慢块、缺 usage），断言透传保真、断连取消、部分计费
- **计费不变量测试**：任意成功/失败/中断路径下，台账变动 = 日志 cost 之和；并发扣减无竞态（乐观锁/原子更新）
- **路由测试**：分组过滤、权重分布、重试不重复、自动禁用/恢复状态机
- **契约测试沿用 Neton 现有约定**（框架流式 API 也要加 contract test）
- 压测：Kotlin/Native 下 500 并发长流的内存/稳定性基线（M0 出报告）

## 12. 里程碑（范围划分，非排期）

| 里程碑 | 内容 |
|--------|------|
| M0 | 框架前置：服务端流式响应（Ktor）、client 长流压测、IR 扩展审计、gateway 路由组 |
| M1 | MVP：TokenGuard、渠道/令牌/定价/额度/日志、ChatCompletions + Embeddings 同协议透传、路由与重试、admin 最小管理页 |
| M2 | 跨协议：Anthropic / Gemini 原生入站 + IR 矩阵全通、Claude Code 实测通过 |
| M3 | 扩展端点：Responses / Images / Audio / Rerank、健康巡检、限流完善 |
| M4 | neton-application-client 底座搭建 + NewGate-console 用户控制台 + 充值打通 module-payment + 兑换码 |
| M5 | 发行：文档站、docker-compose、多节点（Redis）、new-api 数据迁移工具（β）、英文 i18n |

## 13. 开放问题

1. ~~开源许可与依赖开放~~ **已决策（2026-07-21）**：member / payment 等均为自有项目，
   随 NewGate 一并采用开源许可发布；NewGate 建议 Apache-2.0
2. new-api 迁移工具范围：只迁渠道/定价，还是含用户（密码 bcrypt 可移植）与额度
3. Bedrock / Vertex 进 v1.1 的优先级
4. Realtime WebSocket 代理是否永久排除

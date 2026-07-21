# new-api 功能全景拆解 → NewGate 模块/路由组映射

日期：2026-07-21
依据：`/Users/zoujiaqing/projects/NewGate/new-api` 源码实测（router/、controller/、relay/channel/、constant/channel.go、web/src/features/）
配套 spec：`2026-07-21-newgate-design.md`

**总览统计（new-api 现状）：**

| 维度 | 数量 |
|------|------|
| 渠道类型常量 | 56（含 Unknown/Dummy/历史废弃马甲） |
| 入站协议端点（relay-router） | ~50 |
| 管理/用户 API 路径（api-router） | ~170 |
| 前端功能模块（web/src/features） | 26 |

范围标记：✅ v1（spec 已含）｜🔜 v1.1｜🧭 v2 观察｜❌ 不做

---

## 1. 入站协议面 → `gateway` 路由组

| new-api 端点 | 功能 | NewGate |
|---|---|---|
| `/v1/chat/completions` | 聊天补全（核心） | ✅ |
| `/v1/completions`、`/v1/engines/:model/embeddings`、`/v1/edits` | Legacy 端点 | 🔜 completions（老客户端仍多）；edits/engines ❌（OpenAI 已废弃） |
| `/v1/embeddings` | 向量 | ✅ |
| `/v1/messages` | Claude 原生 | ✅ |
| `/v1beta/*`（models、generateContent、openai/models） | Gemini 原生 | ✅ |
| `/v1/responses`、`/responses/compact` | Responses API | ✅（compact 🔜） |
| `/v1/images/generations` | 文生图 | ✅ |
| `/v1/images/edits`、`/variations`、`/image/:id` | 图像编辑/变体 | 🔜 |
| `/v1/audio/speech`、`/transcriptions`、`/translations` | TTS / STT / 翻译 | ✅ speech+transcriptions；translations 🔜 |
| `/v1/rerank` | 重排序 | ✅ |
| `/v1/models`、`/models/:model` | 模型列表（按令牌过滤） | ✅ |
| `/v1/moderations` | 内容审核 | 🔜（纯透传，成本低） |
| `/v1/realtime` | Realtime WebSocket | ❌（spec 非目标） |
| `/v1/files/*`、`/v1/fine-tunes/*` | 文件/微调透传 | ❌ v1，🧭 v2（通用透传通道实现后近乎免费） |
| `/mj/*`、`/submit/*`（imagine/blend/describe/video 等 ~14 个） | Midjourney 代理 | ❌（spec 非目标） |
| `/suno`、`/task/*` | Suno 及异步任务查询 | ❌（spec 非目标） |
| 视频生成（sora/kling/vidu/jimeng/hailuo/doubao，video-router） | 异步视频任务 | ❌ v1，🧭 v2（异步任务框架统一评估） |
| `/pg`（playground 转发）、`/insight-face/swap`、`/notify` | 试玩转发/换脸/回调 | playground 见 §5；其余 ❌ |

## 2. 上游渠道适配器：56 个类型 → NewGate 4+2 个适配器

new-api 的 56 个渠道类型按**实际协议**归并后：

**A. OpenAI 兼容马甲（NewGate 用 1 个「OpenAI 兼容」适配器全覆盖，✅ v1）：**
OpenAI、OpenAIMax、DeepSeek、Moonshot、SiliconFlow、Xai、OpenRouter、Ollama、Xinference、
LingYiWanWu、Mistral、Perplexity、360、MiniMax、Submodel、AdvancedCustom/Custom、
以及纯代理商历史包袱（AIProxy、AIProxyLibrary、API2GPT、OhMyGPT、AIGC2D、AILS、FastGPT、MokaAI）
——共 **24+ 类型折叠为 1 个适配器**，NewGate 以「预设模板」形式内置常用厂商的 base_url/模型清单，体验等同专属渠道类型。

**B. 原生协议（NewGate 专属适配器）：**

| new-api 类型 | NewGate |
|---|---|
| Anthropic | ✅ v1 |
| Gemini | ✅ v1 |
| Azure | ✅ v1 |
| Aws（Bedrock，SigV4） | 🔜 v1.1 |
| VertexAi（GCP OAuth） | 🔜 v1.1 |

**C. 国产原生协议（Baidu/BaiduV2、Zhipu/Zhipu_v4、Xunfei、Tencent、Ali、VolcEngine）：**
这些厂商 **2024 年后全部提供 OpenAI 兼容端点**（百度千帆 v2、智谱、讯飞、混元、DashScope、火山方舟），
NewGate 走 A 类适配器 + 预设模板，**不做原生协议适配** ❌——这是 new-api 难维护的最大历史包袱（8 套私有协议代码）。

**D. 特殊形态：** Cohere（rerank 上游 🔜）、Jina（rerank 上游 ✅）、Coze/Dify（Bot 平台 ❌）、
Replicate（❌）、Cloudflare（A 类模板）、PaLM/Dummy（废弃 ❌）、
任务型渠道（Midjourney/Suno/Kling/Vidu/Jimeng/Sora/DoubaoVideo/Hailuo ❌，同 §1）。

**结论：4 个适配器（v1）+ 2 个（v1.1）≈ 覆盖 new-api 56 类型中仍有活跃价值的 ~40 个。**

## 3. 管理后台功能 → `admin` 路由组

### 3.1 → module-gateway（新增模块，✅ v1 除标注外）

| new-api 功能（controller） | 说明 | NewGate |
|---|---|---|
| channel CRUD / 批量操作 / 启停 | 渠道管理 | ✅ |
| channel-test（连通性测试） | 单渠道/批量测速 | ✅ |
| channel-billing（上游余额查询） | 查渠道 Key 余额 | 🔜（各厂商余额 API 不一） |
| channel_upstream_update / sync_upstream | 从上游同步模型列表 | ✅（`/v1/models` 拉取） |
| channel_affinity_cache | 渠道亲和缓存 | 🧭（多节点优化，v2） |
| token 管理（全局） | 令牌 CRUD/搜索/批量 | ✅ |
| pricing / ratio_config | 模型定价、倍率配置 | ✅（按 spec 决策 B 的 USD/1M 模型） |
| ratio_sync | 从上游/同类站同步倍率 | ✅ 变体：价格表 JSON 导入导出 |
| model_meta / vendor_meta / model_sync / missing_models | 模型元数据、厂商图标、缺失模型检测 | ✅ 精简版（模型目录表）；厂商图标 🔜 |
| log / usedata / stat | 用量日志、消耗统计、看板 | ✅ |
| rankings | 消耗排行榜 | 🔜 |
| redemption | 兑换码 | ✅ |
| group | 用户/渠道分组 | ✅ |
| midjourney / task / system_task | 异步任务管理 | ❌ |
| prefill_group | 参数预填组 | 🧭 |

### 3.2 → module-system（已有能力，直接复用）

| new-api 功能 | NewGate 对应 |
|---|---|
| user 管理（CRUD/搜索/分组/额度调整） | ✅ module-system 用户管理 +（额度字段在 gateway 台账） |
| option / setting（全局设置 KV） | ✅ module-infra 动态配置 + system 字典 |
| notice / home_page_content / about | ✅ 通知公告 CRUD（首页内容做成配置项） |
| audit（审计） | ✅ 操作审计日志（现成，且强于 new-api） |
| setup（初始化向导） | 🔜（首启建管理员，现有 SQL 初始化已覆盖底线） |
| custom-oauth-provider 管理 | ✅ 社交登录配置（system 已有 Google/Telegram，扩展 OIDC 🔜） |
| telegram bot | 🧭 |

### 3.3 → module-payment / module-infra

| new-api 功能 | NewGate 对应 |
|---|---|
| topup（epay/stripe/creem/waffo 多网关） | ✅ module-payment 多渠道网关（具体网关按需接入；epay+stripe 优先） |
| subscription 订阅计划（plans/user_subscriptions） | 🧭 v2（new-api 新增的大功能；NewGate v1 只做按量额度，订阅制等 payment 订单模型评估后再上） |
| payment_compliance | 🧭 随订阅制 |
| system-info / performance / perf-metrics | ✅ module-infra（API 日志/Redis 监控）；进程指标 🔜 |
| uptime_kuma 集成 | 🧭 |
| log-cleanup / disk_cache / gc | ✅ module-infra 定时任务承载日志清理；其余 🧭 |

## 4. 用户控制台功能 → `app` 路由组

| new-api 功能 | NewGate 对应 | 范围 |
|---|---|---|
| 注册/登录/邮箱验证/重置密码 | module-member 会员认证 | ✅ |
| OAuth 登录绑定（GitHub/WeChat/Telegram/自定义 OIDC） | member 社交注册 + system 社交用户 | ✅ 基础（Google/Telegram 现成）；WeChat/OIDC 🔜 |
| passkey / 2FA / sessions 管理 | member 缺口 | 🧭 v2（安全增强包） |
| token 自助管理 | gateway 令牌（本人视角） | ✅ |
| topup 自助充值 + 充值记录 | payment 收银台 → gateway 额度台账 | ✅ |
| redemption 兑换 | gateway 兑换码 | ✅ |
| log/self、self/stat | 本人用量明细与统计 | ✅ |
| checkin 签到送额度 | **member 签到系统现成** + 台账 grant 打通 | ✅（低成本高感知） |
| aff 邀请返利 / aff_transfer 划转 | member 无返利概念，需 gateway 台账联动 | 🔜 v1.1 |
| subscription 自助订阅 | 同 §3.3 | 🧭 v2 |
| profile / preference | member 个人资料 | ✅ |

## 5. 公开页/半公开页（无需登录或登录即可）

| new-api 前端 feature | 说明 | NewGate |
|---|---|---|
| home（首页内容可配置） | 营销首页 | ✅（配置驱动） |
| pricing + models（模型广场） | 公开的模型价目表 | ✅ **建议纳入 v1**：直接读 gateway_model_prices 渲染，成本极低、获客感知强 |
| about / legal（隐私/协议） | 静态内容 | ✅ 配置驱动 |
| rankings | 公开排行榜 | 🔜（可开关） |
| playground / chat | 站内试玩（消耗自己令牌） | 🔜 v1.1（前端调 gateway 端点即可，后端零改动） |
| setup | 初始化向导 | 🔜 |

## 6. 前端 26 个 feature 模块归属速查

- **admin 区**：channels、users、system-settings、redemption-codes、system-info、performance-metrics、dashboard(管理视角)
- **console 区（app）**：keys、wallet、usage-logs、profile、subscriptions(🧭)、dashboard(个人视角)、auth
- **公开区**：home、models、pricing、rankings、about、legal、chat/playground(🔜)、setup(🔜)、errors
- **落位（2026-07-21 决策：双前端）**：admin 区页面进 **NewGate-front**（fork neton-application-front）的 `front-module-gateway`；console 区 + 公开区进 **NewGate-console**（fork 新建底座 neton-application-client，React 19 + shadcn-ui，member 账号体系，云厂商控制台风格）

## 7. spec 修订建议（待确认后并入 spec）

1. **模型广场公开页提升为 v1**（§5，原 spec 未明确公开页）
2. **签到送额度提升为 v1**（member 签到现成，只需台账 grant 联动）
3. **`/v1/completions`（legacy）加入 🔜 清单**（存量客户端兼容）
4. **订阅制（subscription plans）明确为 v2 评估项**——new-api 已把它做成一等公民（4 个支付网关 × 订阅），说明市场有需求，但会显著复杂化计费模型，v1 坚持纯按量
5. **国产厂商策略写明**：一律走 OpenAI 兼容 + 预设模板，永不做原生协议适配（防止长尾腐蚀）
6. **渠道预设模板机制加入 v1**：内置常用厂商（DeepSeek/Moonshot/智谱/通义/硅基流动等）的 base_url 与模型清单，弥补「只有 4 个适配器」相对 56 个渠道类型的体验差

## 8. 补遗（setting/、middleware/、electron/ 二次核查发现）

| new-api 功能 | 说明 | NewGate |
|---|---|---|
| sensitive.go 敏感词过滤 | 请求/响应内容命中词表拦截 | 🔜 v1.1（合规运营刚需，gateway 管线加过滤阶段） |
| turnstile-check | Cloudflare Turnstile 注册/登录人机校验 | 🔜 v1.1（防撸羊毛，member 注册加校验点） |
| secure_verification + 2FA + passkey | 敏感操作二次验证 | 🧭 v2 安全包（与 passkey/2FA 一并） |
| status_code_ranges | 按上游状态码范围定制重试/禁用规则 | ✅ 并入 v1 重试条件配置 |
| auto_group / user_usable_group | 用户自动分组、可用分组开放 | 🔜 v1.1 |
| chat.go 聊天面板快捷链接 | 一键接 ChatGPT-Next-Web 等第三方面板 | 🧭（playground 已覆盖主场景） |
| console_setting / header_nav 主题与导航定制 | 站点主题、自定义导航 | 🔜 基础版（站点名/Logo/首页内容配置），完整主题系统 🧭 |
| request_body_limit / email-verification-rate-limit | 请求体上限、验证码限流 | ✅ spec 已含（32MB 上限、限流体系） |
| reasoning 设置 | thinking 内容转换策略 | ✅ 归入 IR 审计项 2 |
| electron/ 桌面客户端 | 打包桌面 App | ❌（Web 优先，无此规划） |
| deployment / codex_usage / video_proxy | 托管部署管理、Codex 用量、视频代理 | ❌（niche，与不做的任务型 API 绑定） |

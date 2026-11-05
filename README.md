# NetonAPI

面向 LLM API 的开源中转网关：一个 Key 打所有大模型，按 token 计费，自带管理台与用户控制台。
使用 Kotlin/Native，基于 [Neton](https://github.com/netonframework/neton) 框架与 [Neton Application](https://github.com/neton-application/neton-application) 脚手架打造；单个二进制部署，只依赖 PostgreSQL（Redis 可选）。

| 仓库 | 内容 |
|---|---|
| [netonapi/netonapi](https://github.com/netonapi/netonapi) | 服务端 |
| [netonapi/netonapi-admincp](https://github.com/netonapi/netonapi-admincp) | 管理后台 |
| [netonapi/netonapi-web](https://github.com/netonapi/netonapi-web) | 网站前端（门户首页、价格页、用户控制台） |

> 仓库目录与历史命名仍叫 NewGate，产品名是 NetonAPI；两者指同一项目。

## 能做什么

**接入面（客户端怎么打进来）**

| 端点 | 协议 | 说明 |
|---|---|---|
| `/v1/chat/completions`、`/v1/responses`、`/v1/embeddings`、`/v1/images/generations`、`/v1/rerank`、`/v1/audio/*`、`/v1/models` | OpenAI | 任何 OpenAI SDK 直接用，把 base_url 指向网关 |
| `/v1/messages` | Anthropic | Claude Code / Anthropic SDK 直接用（已用真实 Claude Code CLI 验证两轮工具调用） |
| `/v1beta/models/{model}:generateContent` 等 | Gemini | Gemini SDK 直接用 |

**上游面（网关往哪里打）**：OpenAI 兼容站（DeepSeek、Kimi、通义、智谱、Groq、OpenRouter、Ollama…）、
Azure OpenAI、Anthropic、Gemini、AWS Bedrock（SigV4）、Vertex AI（服务账号 OAuth，Anthropic 与 Gemini 两个发布者）。

入站协议与上游协议可以不同：工具调用、图片、thinking/reasoning、缓存用量、mid-conversation system 都会跨协议保真转换；
同协议则最小改写透传（模型映射双向，客户端看不到上游名）。

**钱**：预留 → 结算的两阶段账务（崩溃可恢复，人工复核队列），官方价/售价双轨与毛利可视化，计价组与按用户的协议定价，
按 token / 按次 / 按字符计价，兑换码，在线充值（支付宝/沙箱，可扩展）。

**运营**：管理台概览（收入/成本/毛利、每日柱状图、模型与用户 Top、渠道健康与测速）、渠道测试连通与拉取模型、
定价批量导入与价源定时同步、用量日志、结算复核、Prometheus `/metrics`、邮件通道（SMTP 或厂商 HTTP 接口）。
侧栏按本产品裁剪（38 页，AI 网关排第一组），并预置网关运营 / 财务 / 客服 / 只读四个角色，
建完账号勾一个角色就能用，不必逐条勾菜单。

**用户**：注册 / 登录 / 邮箱找回密码、API Key 自助管理（预算、有效期、模型范围、IP 白名单）、
用量汇总与明细、充值与流水、模型价格表、接入说明。

## 截图

以下截图来自本地演示环境（`harness/demo/up.sh`：虚构的渠道与用户、随机但贴近真实的用量）。

**用户侧**

| 首页 | 控制台 |
|---|---|
| ![首页](https://raw.githubusercontent.com/netonapi/netonapi/main/docs/screenshots/web-home.png) | ![控制台概览](https://raw.githubusercontent.com/netonapi/netonapi/main/docs/screenshots/console-overview.png) |
| **模型与价格**：你的价格、相当于官方价几折、协议价标记 | **用量与额度**：每日消费、按模型 / 按 Key 汇总 |
| ![模型与价格](https://raw.githubusercontent.com/netonapi/netonapi/main/docs/screenshots/console-models.png) | ![用量与额度](https://raw.githubusercontent.com/netonapi/netonapi/main/docs/screenshots/console-usage.png) |

**运营侧**

| 网关概览：收入、成本、毛利 | 模型定价：每个模型在每条渠道上的最差毛利 |
|---|---|
| ![网关概览](https://raw.githubusercontent.com/netonapi/netonapi/main/docs/screenshots/admin-overview.png) | ![模型定价](https://raw.githubusercontent.com/netonapi/netonapi/main/docs/screenshots/admin-pricing.png) |

**协议定价**：给大客户按模型打「官方价 N 折」，实时显示他的价格与毛利，亏本的折扣保存不了。

![协议定价](https://raw.githubusercontent.com/netonapi/netonapi/main/docs/screenshots/admin-negotiated-detail.png)

## 能力对照

NetonAPI 不是在 one-api / new-api 上改出来的分支，而是从**运营平台**的角度重新设计：定价以官方价为锚、每条渠道核算真实成本、
亏本的价格保存不了、每一笔扣费都能按「单价 × tokens」逐笔对上。下表对照的是两个最主流的开源中转站项目。

| 能力 | NetonAPI 1.0 | [new-api](https://github.com/QuantumNous/new-api) | [one-api](https://github.com/songquanpeng/one-api) |
|---|---|---|---|
| **定价方式** | 以官方价为锚：售价 = 官方价 × 加价率；分组、单个用户都可按模型谈「官方价 N 折」 | 倍率体系：模型倍率 × 补全倍率 × 分组倍率；按次固定价；分档表达式定价 | 倍率体系：分组倍率 × 模型倍率 × 补全倍率 |
| **按用户 × 模型的协议价** | 有（「协议定价」页：搜用户、逐模型打折、可批量） | 按用户分组倍率区分 | 按用户分组倍率区分 |
| **渠道真实成本** | 每条渠道记录拿货价（官方价折扣 / 拉取上游价目接口 / 按模型手填），异常变动挂起待确认 | 公开文档未涉及 | 公开文档未涉及 |
| **毛利保护** | 售价低于渠道成本的定价**保存不了**；定价体检列出每个「分组 × 渠道」的最差毛利；利润看板 | 公开文档未涉及 | 公开文档未涉及 |
| **官方价维护** | 定时从价源同步官方价，涨跌先挂起由运营确认，完整调价记录 | 倍率设置，可同步上游倍率 | 内置默认倍率，手动调整 |
| **扣费与展示** | 扣费 = tokens × 用户看到的单价（逐项取整），控制台、价格表、账单三处一致；缓存价缺失时按输入价计，不白送缓存命中 | 预扣后按实际用量多退少补 | 预扣后按实际用量结算 |
| **账务** | 预留 → 结算两阶段，进程崩溃可恢复，异常进入人工复核队列；每笔请求冻结定价快照 | 预扣 + 后结算 | 预扣 + 后结算 |
| **计费分组** | 由 API Key 决定：运营可直接指定到某把 Key（专线 / 特价） | 用户分组，令牌可选分组 | 用户分组、渠道分组 |
| **API Key 安全** | 只在创建时显示一次，库里只存哈希；渠道上游 Key 加密存储 | 列表中可查看、复制 | 列表中可查看、复制 |
| **接入协议** | OpenAI（Chat、Responses）、Anthropic、Gemini 原生入口，**任意方向互转**（工具调用、图片、thinking、缓存用量保真） | OpenAI Chat、Responses、Anthropic、Gemini 四种文本协议互转；另有 Realtime WebSocket | 统一为 OpenAI 格式 |
| **上游类型** | OpenAI 兼容站、Azure OpenAI、Anthropic、Gemini、AWS Bedrock、Vertex AI | 数十种，含国内外厂商 | 30 余家国内外厂商 |
| **渠道容错** | 优先级 + 权重；失败自动换渠道；上游说「没有这个模型」时换渠道而不是报错给用户；Key 自动停用与冷却；定时测速 | 优先级 + 权重、重试、渠道亲和、多 Key | 负载均衡、失败重试、按成功率自动禁用 |
| **任务类接口**（Midjourney、视频等） | 暂不支持 | 支持（JS 插件扩展） | 不支持 |
| **运营权限** | 菜单与按钮级权限，预置网关运营 / 财务 / 客服 / 只读四个角色 | 细粒度权限 | 管理员 / 超级管理员 |
| **用户登录** | 账号密码、手机验证码（需配短信）、邮箱找回密码 | OAuth / OIDC、Passkey、两步验证 | 邮箱、GitHub、飞书、微信公众号 |
| **充值** | 管理员手动充值、兑换码、在线支付（支付宝、四方支付，可扩展）；支付密钥只写不读 | 兑换码、易支付、Stripe、订阅 | 兑换码、充值链接 |
| **实现与部署** | Kotlin/Native **单个原生可执行文件**，运行期无 JVM；PostgreSQL（Redis 可选） | Go 单二进制 / Docker；SQLite / MySQL / PostgreSQL | Go 单二进制 / Docker；SQLite / MySQL |
| **项目状态** | 1.0.0 正式版 | 持续发布（v1.0.0-rc 系列） | 最新版本 v0.6.10（2025-02），此后无新版本 |

new-api、one-api 两列依据各自公开的 README 与文档整理（2026-11），「公开文档未涉及」表示没有找到相关说明，不代表一定没有；细节以对方最新版本为准。

## 仓库布局

```
NewGate/                 ← 本仓：编排、harness、文档
  netonapi-backend/      服务端（GitHub 仓 netonapi/netonapi）：网关模块 module-gateway 与装配，含 Dockerfile
  netonapi-frontend/     管理后台（netonapi/netonapi-admincp）：Next.js，网关页面在 packages/front-gateway
  netonapi-client/       网站前端（netonapi/netonapi-web）：门户首页、价格页与用户控制台，网关页面在 packages/client-gateway
  harness/               端到端 harness：真网关 + 假上游 + 隔离数据库
  docker-compose.yml     后端 + PostgreSQL + Redis + 两个前端 + Caddy 边缘
  deploy/                Caddyfile 与生产 compose 叠加
Neton/                   ← 同级目录：框架与 Neton Application 通用模块
```

## 快速开始

Docker（推荐）：

```bash
cp .env.example .env        # 填 POSTGRES_PASSWORD / JWT_SECRET / CHANNEL_KEY_ENC_KEY
docker compose up -d --build
# 管理台 http://localhost:8888  用户控制台 http://localhost:8880  后端直连 http://localhost:8800
```

本机开发（后端 8800、控制台 8880、管理台 8888）与全部环境变量、上线检查表见 [DEPLOY.md](DEPLOY.md)。
管理员种子账号 `admin / admin123`，上线前改掉。

## 文档

- [DEPLOY.md](DEPLOY.md)：部署、密钥、定价与毛利、收款、渠道类型、端点能力、邮件通道、可观测性、升级
- 服务端仓 `netonapi-backend/docs/`：产品规范（计价、模型目录、API Key、充值、转发错误、线上演练等）
- `netonapi-backend/module-gateway/docs/`：网关模块的结算设计与上游适配 / 转码规范
- `harness/run.sh`：每条场景的注释就是行为规格

## 验证

```bash
./harness/run.sh                      # 需要本机 PostgreSQL 与 Redis；本机跑着后端时用 NETONAPI_HARNESS_PORT=8801
cd netonapi-backend && ./gradlew :module-gateway:macosArm64Test -Pneton.database.driver=postgres
```

## 许可

Apache-2.0（见各仓 LICENSE）。

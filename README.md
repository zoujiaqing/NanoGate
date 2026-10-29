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

**钱**：预留 → 结算的两阶段账务（崩溃可恢复，人工复核队列），官方价/售价双轨与毛利可视化，计价组与用户例外，
按 token / 按次 / 按字符计价，兑换码，在线充值（支付宝/沙箱，可扩展）。

**运营**：管理台概览（收入/成本/毛利、每日柱状图、模型与用户 Top、渠道健康与测速）、渠道测试连通与拉取模型、
定价批量导入与价源定时同步、用量日志、结算复核、Prometheus `/metrics`、邮件通道（SMTP 或厂商 HTTP 接口）。
侧栏按本产品裁剪（38 页，AI 网关排第一组），并预置网关运营 / 财务 / 客服 / 只读四个角色，
建完账号勾一个角色就能用，不必逐条勾菜单。

**用户**：注册 / 登录 / 邮箱找回密码、API Key 自助管理（预算、有效期、模型范围、IP 白名单）、
用量汇总与明细、充值与流水、模型价格表、接入说明。

## 能力对照

| 能力 | NetonAPI | new-api |
|---|---|---|
| 实现与部署 | Kotlin/Native 单个静态可执行文件，运行期无 JVM | Go 单二进制 / Docker |
| 数据库 | PostgreSQL（Redis 可选） | SQLite / MySQL / PostgreSQL（Redis 可选） |
| 接入协议 | OpenAI、Anthropic、Gemini 三种原生格式，任意方向互转（工具调用、图片、thinking、缓存用量跨协议保真） | 以 OpenAI 格式为主，支持 Claude、Gemini 格式 |
| 上游类型 | OpenAI 兼容、Azure OpenAI、Anthropic、Gemini、AWS Bedrock、Vertex AI | 数十种渠道类型，含国内外厂商与 Midjourney、Suno 等任务类上游 |
| 渠道调度 | 优先级 + 权重，失败换渠道，Key 自动停用与冷却，测速与连通测试 | 优先级 + 权重，失败重试，自动禁用 |
| 售价 | 以官方价为锚：平台价 × 分组倍率；分组 / 用户可按模型设约定价（官方价 N 折或固定价）；支持分档计价 | 模型倍率 × 补全倍率 × 分组倍率，或按次固定价 |
| 渠道成本与毛利 | 每条渠道记录真实成本（官方价折扣 / 拉取上游价目 / 按模型手填），低于成本的定价直接拦截，定价体检与毛利报表 | 不核算渠道成本 |
| 官方价维护 | 定时从价源同步官方价，异常变动挂起待确认，保留调价记录 | 手动维护倍率，可同步上游倍率 |
| 账务 | 预留 → 结算两阶段，进程崩溃可恢复，异常进入人工复核 | 预扣额度，请求结束后多退少补 |
| 计费分组 | 由 API Key 决定（用户在可选分组里选，运营可指定或收回） | 用户分组，令牌可选分组 |
| API Key | 只在创建时显示一次，库里不存明文 | 可随时在列表里查看、复制 |
| 充值 | 管理员手动充值、兑换码、在线充值（支付宝、四方支付，可扩展）；支付通道密钥只写不读 | 兑换码、易支付、Stripe |
| 用户登录 | 账号密码、邮箱找回密码 | 账号密码，另有 GitHub、OIDC、Telegram、微信等第三方登录与两步验证 |
| 任务类接口 | 不支持（Midjourney、Suno、视频生成） | 支持 |
| 运营权限 | 菜单与按钮级权限，预置网关运营 / 财务 / 客服 / 只读角色 | 管理员 / 超级管理员 |

new-api 一列依据其公开文档整理，细节以 new-api 最新版本为准。

## 仓库布局

```
NewGate/                 ← 本仓：编排、harness、文档
  netonapi-backend/      服务端（GitHub 仓 netonapi/netonapi）：装配 Neton 各模块，含 Dockerfile
  netonapi-frontend/     管理后台（netonapi/netonapi-admincp）：Next.js，装配 canonical 前端模块
  netonapi-client/       网站前端（netonapi/netonapi-web）：门户首页、价格页与用户控制台，Next.js
  harness/               端到端 harness：真网关 + 假上游 + 隔离数据库
  docker-compose.yml     后端 + PostgreSQL + Redis + 两个前端 + Caddy 边缘
  deploy/                Caddyfile 与生产 compose 叠加
Neton/                   ← 同级目录：框架与 canonical 模块（module-gateway 是网关核心）
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
- `Neton/neton-application-module-gateway/docs/`：网关模块的结算设计与上游适配 / 转码规范
- `harness/run.sh`：每条场景的注释就是行为规格

## 验证

```bash
./harness/run.sh                      # 需要本机 PostgreSQL 与 Redis；本机跑着后端时用 NETONAPI_HARNESS_PORT=8801
cd netonapi-backend && ./gradlew :module-gateway:macosArm64Test -Pneton.database.driver=postgres
```

## 许可

Apache-2.0（见各仓 LICENSE）。

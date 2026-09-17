# NanoGate

面向 LLM API 的开源中转网关：一个 Key 打所有大模型，按 token 计费，自带管理台与用户控制台。
对标 new-api，用 Neton（Kotlin/Native）实现，单二进制部署，只依赖 PostgreSQL（Redis 可选）。

> 仓库目录与历史命名仍叫 NewGate，产品名是 NanoGate；两者指同一项目。

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

## 仓库布局

```
NewGate/                 ← 本仓：编排、harness、文档
  newgate/               后端发行版（装配 Neton 各模块，含 Dockerfile）
  newgate-front/         管理台（Next.js，装配 canonical 前端模块）
  newgate-client/        用户控制台（Next.js）
  harness/               端到端 harness：真网关 + 假上游 + 隔离数据库，170 条断言
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
- [HANDOFF.md](HANDOFF.md)：项目交接：已完成 / 未完成 / 已知边界
- `docs/superpowers/specs/`：设计文档（架构、协议转换矩阵、账务模型、决策记录）
- `Neton/neton-application-module-gateway/docs/`：网关模块的结算设计与上游适配 / 转码规范
- `harness/run.sh`：每条场景的注释就是行为规格

## 验证

```bash
./harness/run.sh                      # 需要本机 PostgreSQL 与 Redis；本机跑着后端时用 NEWGATE_HARNESS_PORT=8801
cd newgate && ./gradlew :module-gateway:macosArm64Test -Pneton.database.driver=postgres
```

## 许可

Apache-2.0（见各仓 LICENSE）。

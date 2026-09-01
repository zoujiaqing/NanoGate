# NanoGate 部署

单机 Docker 部署。PostgreSQL 与 Redis 都在 compose 内，不需要另外准备数据库。
（产品曾用名 NewGate；下文目录名 `NewGate/`、`newgate/` 为本地布局名，暂不随改名变动。）

## 依赖仓库布局

镜像用 Gradle composite build，构建上下文必须能看到同级的框架与模块仓库：

```
projects/
├── neton/                              # 框架
├── neton-application-module-member/
├── neton-application-module-payment/
├── neton-application-module-platform/
├── neton-application-module-gateway/
└── NewGate/
    ├── newgate/                        # 应用（Dockerfile 在此）
    └── docker-compose.yml
```

## 启动

```bash
cd NewGate
cp .env.example .env
# 填写 POSTGRES_PASSWORD、JWT_SECRET、CHANNEL_KEY_ENC_KEY（见下）
docker compose up -d
```

迁移作为独立的一次性服务先跑完，成功后才启动网关——迁移失败时不会有服务在半套 schema 上接流量。

## 必须设置的密钥

| 变量 | 生成方式 | 不设置的后果 |
|---|---|---|
| `POSTGRES_PASSWORD` | 自定 | compose 直接报错，不会用弱口令启动 |
| `JWT_SECRET` | `openssl rand -base64 48` | 同上；用默认值等于管理台可被任意签发令牌 |
| `CHANNEL_KEY_ENC_KEY` | `openssl rand -base64 32` | 渠道 API Key 明文入库，**数据库泄露 = 你采购的所有上游 Key 泄露** |

`CHANNEL_KEY_ENC_KEY` 可以后补：配置后新写入的 Key 会加密，存量明文仍可读，无需停机迁移。
但请尽早配置，并把它与数据库备份分开保管——两者放在一起等于没加密。

## 定价与毛利

计价是**双轨**的，两轨都固化在每笔请求的定价快照里，事后可逐笔核算毛利：

| 轨道 | 公式 | 落到哪 |
|---|---|---|
| 售价（收入） | 模型 `sale_override` 逐字段覆盖，未覆盖字段 = 官方价 × `SALE_MARKUP`；再 × 用户组倍率 | 用户扣款 `charged` |
| 成本 | 官方价 × 渠道 `cost_discount` | 结算行与用量日志的 `cost`，不动用户余额 |

- 定价表里填的一律是**官方价**；给单个模型单独定价用 `sale_override`，整体加价调 `SALE_MARKUP`。
- `MIN_MARGIN` 是发布闸门：售价任一维低于「官方成本 × 该倍率」时管理台拒绝保存（默认 `1`，即不许亏本卖）。
- 闸门只挡「配错价」。折扣 >1 的渠道、倍率 <1 的用户组仍可能把单笔毛利压成负数，
  这类请求照常服务但会记 `margin inversion` 告警——请把它接进监控。
- 定价数据非法（价格串坏、`sale_override` 不是合法 JSON、倍率配错）时请求在入口就被拒
  （`500 model_pricing_invalid`），不会带着坏价进入结算；已在途请求的快照损坏则保留预留转人工复核。

## 端点能力

渠道除了「支持哪些模型」，还要声明「能服务哪些端点」（管理台渠道表单的**端点能力**，即 `gateway_channels.capabilities`）：

| 能力 | 覆盖端点 |
|---|---|
| `chat` | `/v1/chat/completions`、`/v1/messages`、Gemini `:generateContent` |
| `embeddings` | `/v1/embeddings`、Gemini `:embedContent` / `:batchEmbedContents` |

- 默认只有 `chat`。**升级后确实提供向量的渠道必须补上 `embeddings`**，否则该端点会明确回 `404 model_not_found`——
  宁可报错，也不把向量请求送进 chat 上游、再用上游的 404 来发现配错（那时钱已预留、日志已脏、重试已撞三遍）。
- 模型名命中但没有对应能力的渠道不会被选中：不预留资金、不调上游、不产生错误日志。
- 无候选时的状态码区分「稍后可能可用」（无启用渠道 / 全部在 429 冷却 → `503`）与
  「配置不变就永远不会可用」（模型没配 / 能力没声明 / 分组不通 → `404`），日志会写明卡在哪一环。

## 上线前检查

- [ ] 三个密钥都已设置，且不是示例值
- [ ] 数据库端口未对公网暴露（compose 默认只 `expose` 不 `ports`）
- [ ] 网关放在 TLS 终止层之后（本服务不处理证书）
- [ ] 为令牌设置 RPM / TPM / 并发上限——不限意味着单个用户就能打爆你的上游配额与成本
- [ ] 模型定价已配置：**未配定价的模型会被拒绝**（宁可拒绝也不免费放行）
- [ ] 售价与毛利符合经营策略：`SALE_MARKUP` / `MIN_MARGIN` 已设置（默认不加价、不许亏本卖）
- [ ] 按 token 计价的模型配了「默认输出上限」，否则请求必须自带 `max_tokens`
- [ ] 提供向量的渠道已声明 `embeddings` 能力（默认只有 `chat`，未声明的端点会 404）
- [ ] 定期查看管理台「结算待处理」：这些记录仍占用用户预留额度，需人工裁定

## 反向代理

网关自身不终止 TLS。前置 Nginx/Caddy 时请注意：

- 转发 `X-Forwarded-For`——令牌 IP 白名单依赖它，且该头**可被伪造**，
  必须同时在网络层限制只有可信代理能连到网关；
- 流式响应需关闭代理缓冲（Nginx：`proxy_buffering off;`），否则 SSE 会被攒着一次性吐出。

## 升级

```bash
git -C .. pull --rebase   # 各依赖仓库同理
docker compose build
docker compose up -d
```

迁移脚本一旦应用到保留数据库即冻结，升级只会追加新脚本，不会改写已应用的脚本。

## 数据库

只支持 **PostgreSQL**。交付形态固定为本 compose，因此不承担多方言成本；
`sql/mysql/` 冻结在 V003，不作为支持目标。

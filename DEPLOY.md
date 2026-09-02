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
- [ ] 前置反代时已设 `NEWGATE_TRUSTED_PROXIES`，否则令牌 IP 白名单看到的是代理自己的地址
- [ ] 多实例部署共用同一个 Redis，否则限流上限被放大到实例数倍
- [ ] 网关容器的出网已收敛（云元数据服务与内网不可达）——写入时 SSRF 校验挡不住 DNS 重绑定
- [ ] 为令牌设置 RPM / TPM / 并发上限——不限意味着单个用户就能打爆你的上游配额与成本
- [ ] 模型定价已配置：**未配定价的模型会被拒绝**（宁可拒绝也不免费放行）
- [ ] 售价与毛利符合经营策略：`SALE_MARKUP` / `MIN_MARGIN` 已设置（默认不加价、不许亏本卖）
- [ ] 按 token 计价的模型配了「默认输出上限」，否则请求必须自带 `max_tokens`
- [ ] 提供向量的渠道已声明 `embeddings` 能力（默认只有 `chat`，未声明的端点会 404）
- [ ] 定期查看管理台「结算待处理」：这些记录仍占用用户预留额度，需人工裁定

## 反向代理

网关自身不终止 TLS。前置 Nginx/Caddy 时请注意：

- 流式响应需关闭代理缓冲（Nginx：`proxy_buffering off;`），否则 SSE 会被攒着一次性吐出。
- **`NEWGATE_TRUSTED_PROXIES` 决定网关认哪个地址是「客户端」**，令牌 IP 白名单完全建在它上面：

  | 配置 | 网关认定的客户端 IP | 后果 |
  |---|---|---|
  | 未设置（默认） | TCP 对端地址（= 你的反代） | `X-Forwarded-For` / `X-Real-IP` **一律忽略**。伪造转发头绕不过白名单，但所有用户共用代理这一个身份：白名单要么全过、要么全不过 |
  | `NEWGATE_TRUSTED_PROXIES=10.0.0.0/8,127.0.0.1` | 从 `X-Forwarded-For` **最右**往左剥掉每一跳可信代理，停在第一个不可信地址 | 才是真实客户端 IP |

  格式：逗号分隔的精确 IP 或 IPv4 CIDR（IPv6 只支持精确地址）。**空 = 谁都不信**，这是刻意的默认：
  宁可白名单退化成「按代理判定」，也不能让任何客户端用一个请求头把自己伪装成白名单里的 IP。
  多级代理要把每一跳都列进去；只列最近一跳会让剥链提前停下、拿到上一级代理的地址。
- 为什么不能直接采信 `X-Forwarded-For`：它由客户端自由填写，直连网关时攻击者写什么就是什么；
  经反代时反代通常把真实对端**追加到链尾**，所以剥链必须从右往左、停在第一个不可信地址，
  客户端塞在链首的白名单 IP 一律不算数。
- 网络层仍建议只允许反代连到网关端口：不是为了防 IP 伪造（对端地址伪造不了，上面那条已经关掉），
  而是为了让 TLS / WAF / 代理侧限流这些控制不被直连绕过。

## 上游地址与 SSRF

渠道的 `baseUrl` / `proxyUrl` 决定网关往哪儿发请求，配错（或被越权改）就等于把网关变成打内网的跳板。
写入时做两层校验，任一层不过即 `400` 且不落库：

1. **字面量**：非 http(s)、带 userinfo、回环 / RFC1918 / 链路本地（含云元数据 `169.254.169.254`）/
   IPv6 ULA 与链路本地 / CGNAT / `0.0.0.0/8`，以及 `localhost`、`*.localhost`、`*.local`、`*.internal`。
2. **DNS 复查**：域名再解析一次，**任一** A/AAAA 记录落在上述范围即拒绝（多条记录里混一个内网地址
   正是绕过一次性检查的常见手法）；解析不出来一律 fail-closed——把「DNS 挂了」当成「地址安全」
   是这类校验最典型的失效方式。

必须知道的边界：

- 这是**写入时**检查，挡不住「先指向公网通过校验、再改 DNS 记录指向内网」的重绑定。那一层只能靠
  部署侧出网过滤：给网关容器一个只允许出公网 443/80 的 egress 策略，并在云上关掉/挡住元数据服务
  （IMDSv2 + 安全组）。**不要把出网过滤当成可选项**——它是唯一能覆盖重绑定的一层。
- 解析是阻塞调用，只发生在管理员写渠道这类低频路径，不进中转热路径（每请求解析一次等于把 DNS
  变成延迟与故障源）。
- 自托管确实要连内网上游时设 `NEWGATE_ALLOW_PRIVATE_UPSTREAM=true`：它同时关掉上面两层
  （连内网上游是明确的经营决定，不该靠校验疏漏来实现）。
- Windows(mingw) 构建**不提供解析器**：WinSock 的 `getaddrinfo` 需要先 `WSAStartup`，而初始化时序由
  HTTP 引擎掌握、不在本模块手里，且该目标在本仓只能交叉编译、无法运行验证——一旦解析在运行期失败，
  fail-closed 会让 Windows 部署完全无法新增域名渠道。此时只剩字面量校验，每次渠道写入会打一条降级
  告警（日志里搜 `DNS re-check unavailable`）。生产请用 Linux 构建。

## Redis

- 单实例不配也能跑：限流退化为**进程内**计数，语义不变但不跨实例共享，
  N 个实例的实际放行量约为配置上限 × N。多实例部署必须共用同一个 Redis
  （默认的 compose 已内置 Redis，所以上面这条通常已经满足）。
- RPM / TPM / 并发计数走服务端 Lua 脚本（`INCRBY` 与 `EXPIRE` 一次执行）：并发下不丢增量，
  也不会因为进程在两条命令之间崩溃而留下永不过期的计数键。Redis 抖动时降级为进程内计数并告警，
  不会让请求整体失败。
- 与其他 Neton 应用共用 Redis 时用 `keyPrefix`（`config/redis.conf`，根级平铺、**不要**写 `[redis]` 段）
  隔开命名空间；限流键形如 `<prefix>:ngrl:rpm:<tokenId>:<分钟窗口>`，窗口键带 120s TTL 自动消失。
- 别把网关和其他项目混在同一个 db 里再做 `flushdb`：harness 就是因此自带一个隔离实例
  （独立端口 + 独立 db + 独立 `keyPrefix` + 关持久化）。

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

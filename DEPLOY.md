# NanoGate 部署

单机 Docker 部署。PostgreSQL 与 Redis 都在 compose 内，不需要另外准备数据库。
（产品曾用名 NewGate；下文目录名 `NewGate/`、`newgate/` 为本地布局名，暂不随改名变动。）

## 依赖仓库布局

镜像用 Gradle composite build，`newgate/settings.gradle.kts` 里写死了 `../../Neton/<repo>`：
本仓必须正好在那层目录的**两层深处**，框架与六个 canonical 模块必须落在同层的 `Neton/` 下。
外层目录名（`Neton`、`NewGate`）也是契约的一部分——`newgate/Dockerfile` 的 `COPY` 源同样写死了它们。

```
projects/
├── Neton/
│   ├── neton/                              # 框架（includeBuild）
│   ├── geolite4k/                          # GeoIP（includeBuild）
│   ├── neton-application-module-system/
│   ├── neton-application-module-infra/
│   ├── neton-application-module-member/
│   ├── neton-application-module-payment/
│   ├── neton-application-module-platform/
│   └── neton-application-module-gateway/   # NanoGate 的核心模块
└── NewGate/                                # 本仓（含 docker-compose.yml）
    ├── newgate/                            # 后端发行版（Dockerfile 在此）
    ├── newgate-front/                      # 管理台
    └── newgate-client/                     # 用户控制台
```

> ⚠️ 八个仓里有六个是公开的（`netonframework/neton`、`netonframework/geolite4k`、
> `neton-application/neton-application-module-{system,member,payment,platform}`），但
> **`neton-application-module-infra` 与 `neton-application-module-gateway` 目前是私有仓**。
> 没有这两个仓的读权限就 clone 不全、也就构建不出镜像；它们转公开之前，本仓的公开只是
> 「源码可读」，不是「人人可自建」。前端同理（见各自 README）。

> ⚠️ 下文 Docker 路径**尚未在实机验证过**（修正时的开发机上 Docker daemon 未运行）。
> `COPY` 布局是按 `settings.gradle.kts` 的路径推导修正的，此前它既漏了三个必需仓、
> 又把应用放在了 `../../Neton` 解不到的深度。首次 `docker compose build` 请当作待验证项，
> 失败时先看是不是布局问题。

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

## 收款与获客

下面几条都是「不配就不可用」，但**不会在启动时报错** —— 启动检查只覆盖密钥与数据库，
钱的功能是等到第一个用户用到时才失败（而且失败在用户那边，不在你的日志监控里）。

### 充值：`QUOTA_PER_PRICE_UNIT`（不设 = 收不到钱）

每 1 单位 `pay_orders.price`（法币最小单位，如「分」）发多少 μUSD 额度（1 USD = 1000000 μUSD）。

**不设的后果是充值功能整个不可用**：用户每次下单都拿到 `500 quota recharge is not configured`。
这是有意的设计 —— 静默按 1:1 发放等于白送钱，而且不会留下任何日志痕迹，所以账务宁可拒绝也不猜汇率。
没有普适默认值：它取决于你按什么币种定价、以及你想让「1 元」对应多少额度。

额度由服务端按这个汇率算出，**不接受客户端指定** —— 客户端能同时填 price 与 amount 就等于自己给自己定价。

### 邀请奖励：`INVITE_REWARD_INVITER` / `INVITE_REWARD_INVITEE`

邀请达成时给邀请人 / 被邀请人各发一笔网关额度（μUSD）。留空或 `0` = 该角色不发奖。

- **默认不发**。发钱的路径不该因为一次升级就自己打开，要开必须显式配置。
- 非法值（`1e3`、`-5`、带单位的串）**不会**被静默当成 0：该角色不发奖并记 ERROR，
  另一个角色照常发。理由是「运营以为活动已上线、客服按活动口径答复用户、而账上什么都没有」
  比不发奖糟得多。
- 生效值在启动日志里：`grep "invite reward attached"`。没配额度时每次邀请也会记一行
  `invite reward skipped`，用来区分「评估过而不发」与「链路没装配」—— 两者账面上完全一样。
- 幂等由台账 ref 钉住（`invite:{记录id}:inviter` / `:invitee`），所以补发不会二次入账；
  补发入口 `POST /admin/member/invite-code/retry-invite-reward/{recordId}`（需 `member:invite-code:update`）。
  该接口返回 200 只代表事件已重放，**不代表已到账**，到账与否要去台账按 ref 查。
- **已知边界**：挡得住「绑自己的码」，挡不住「同一个人注册多个账号互邀」—— 那需要设备/IP 指纹
  与人工审核。开启前请知道自己是在一个可被刷的通道上发钱，并对邀请人的累计邀请数设告警。

### 兑换码

管理端批量生成、用户端兑换，无需环境变量。面额只由管理员指定，兑换时不接受客户端改写。
码体 20 字符 × 31 字符集 ≈ 99 bit，因此兑换接口没有额外限流；这条取舍由单测钉住
（缩短码长或缩小字符集会让测试红）。码外泄时用「整批作废」止损，它只影响未用的码 ——
已用的是历史事实，要收回已发放的额度请走管理端的额度调整另记一条台账。

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
- [ ] 前置反代时已设 `TRUSTED_PROXIES`（容器内为 `NEWGATE_TRUSTED_PROXIES`），否则令牌 IP 白名单看到的是代理自己的地址
- [ ] 多实例部署共用同一个 Redis，否则限流上限被放大到实例数倍
- [ ] 网关容器的出网已收敛（云元数据服务与内网不可达）——写入时 SSRF 校验挡不住 DNS 重绑定
- [ ] 为令牌设置 RPM / TPM / 并发上限——不限意味着单个用户就能打爆你的上游配额与成本
- [ ] 模型定价已配置：**未配定价的模型会被拒绝**（宁可拒绝也不免费放行）
- [ ] 要收钱就设 `QUOTA_PER_PRICE_UNIT`：**不设则充值功能整个不可用**（用户每次下单都拿到 500）
- [ ] 要开邀请奖励就设 `INVITE_REWARD_INVITER` / `INVITE_REWARD_INVITEE`（默认不发；启动日志会念一遍生效值）
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
- 与其他 Neton 应用共用 Redis 时用 `keyPrefix` 隔开命名空间；限流键形如
  `<prefix>:ngrl:rpm:<tokenId>:<分钟窗口>`，窗口键带 120s TTL 自动消失。
  本发行版**没附带** `config/redis.conf`（框架按「文件名 = 命名空间」可选加载，缺文件就走默认值），
  要设前缀有两条路：在 `newgate/application/config/` 下自建 `redis.conf`（根级平铺
  `keyPrefix = "nanogate"`，**不要**写 `[redis]` 段），或直接给环境变量 `NETON_REDIS__KEYPREFIX`。
- 别把网关和其他项目混在同一个 db 里再做 `flushdb`：harness 就是因此自带一个隔离实例
  （独立端口 + 独立 db + 独立 `keyPrefix` + 关持久化）。

## 升级

```bash
git pull --rebase                       # 本仓（NewGate/，compose 与文档）
git -C newgate pull --rebase            # 后端发行版（嵌套仓，不归上面那条管）
for r in ../Neton/*/; do git -C "$r" pull --rebase; done   # 框架与各 canonical 模块
docker compose build
docker compose up -d
```

迁移脚本一旦应用到保留数据库即冻结，升级只会追加新脚本，不会改写已应用的脚本。

**beta1 是这条规则的唯一例外，而且打破得很彻底**：本发行版六个模块里有五个（gateway /
infra / member / payment / platform）把全部历史脚本按顺序拼成了一个 `V001__baseline.sql`，
原文件删除。所以 **beta1 之前建起来的库无法原地升级，只能重建**。引擎按 SHA-256 逐字节
比对（一字节变化即视为脚本变更），对已应用脚本的不一致直接 fail-fast：`migrate status`
退出码 3，正常启动的 precheck 在 `Neton.run` 之前就打 `STARTUP ABORTED` 并 `exitProcess(1)`，
不会绑定任何端口。一个停在 7 月的库跑出来是 `6 changed / 27 missing_on_disk / 4 pending`。

**不要靠改 `neton_schema_history` 的 checksum 来「重新盖章」过关**——那条路在本发行版会造出
一个能启动、但缺表的库，比拒绝启动糟得多。原因是 squash 之后**版本号槽位被复用**了：
gateway 的 `V002` 在 beta1 之前是 `seed_menus`（内容已并入 baseline），之后是
`group_billing_identity`（给 `gateway_groups` 加 `code` / `member_group_id`、建
`gateway_group_overrides`）。把 V002 的 checksum 盖成新值，等于宣称这份从没跑过的脚本已经
应用，引擎会跳过它：应用照常启动，然后在第一次查询 `gateway_groups.code` 时才炸。实测那个
7 月的库，`gateway_groups` 只有 id/name/ratio/description/deleted/created_at/updated_at，
而 `gateway_group_overrides`、`gateway_settlements`、`gateway_redemption_codes` 三张表不存在。

升级 beta1 之前的库，正确动作是重建；数据要留就先自己导出来（`gateway_channels` /
`gateway_tokens` / 钱包与订单表），迁移跑完再导回：

```bash
dropdb <dbname> && createdb <dbname>
./application.kexe migrate up     # 或交给 compose 里的一次性 migrate 服务
```

beta1 之后冻结规则重新生效：新增能力一律追加 V005、V006……，不再改写已应用的文件。

另注：`migrate status` 的 summary 只统计 executed / pending / changed / failed 四类，
`missing_on_disk` 不在其中，所以 `0 executed, 4 pending, 6 changed, 0 failed` 加不回 history
表的行数。判断状态要看逐行输出，别只看 summary。

## 数据库

只支持 **PostgreSQL**。交付形态固定为本 compose，因此不承担多方言成本。

`module-gateway` 是唯一同时带 `sql/mysql/` 与 `sql/sqlite/` 的模块（两边都已到 V004），
但这两方言**跑不起来**，也不是支持目标：其余模块（system / infra / member / payment /
platform / cs）的 `neton.migration.dialects` 都硬编码 `postgresql`，而 `system_users` /
`system_roles` / `system_menus` 只由 `module-infra` 的 postgresql V001 建。所以
`-Pneton.database.driver=mysql` 能编过、驱动也能连上，却会在 gateway 第一条碰
`system_menus` 的迁移上失败。本发行版从不设置 `neton.database.driver`（默认 postgres），
那两个目录里的 SQL 连编进二进制都不会。

结论：改 schema **只需改 `sql/postgresql/`**。那两个目录是历史遗留，别照着它们补新脚本 ——
补齐了也跑不到，只会让人误以为 mysql 是支持目标。要真支持 mysql，得先给 infra 等模块
补方言（含 `system_menus` 的建表），那是一个独立的、比 gateway 大得多的工程。
